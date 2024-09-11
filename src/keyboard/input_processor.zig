const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const ContextMap = std.StringHashMap(*CallbackMap);
const CallbackMap = std.AutoHashMap(u128, Callback);
const Callback = struct {
    f: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,
    quick: bool = false,
};

const MappingCouncil = struct {
    a: Allocator,
    downs: *ContextMap,
    ups: *ContextMap,
    current_context_id: []const u8 = "",

    pub fn init(a: Allocator) !*@This() {
        const downs = try a.create(ContextMap);
        downs.* = ContextMap.init(a);

        const ups = try a.create(ContextMap);
        ups.* = ContextMap.init(a);

        const self = try a.create(@This());
        self.* = .{ .a = a, .downs = downs, .ups = ups };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        var down_iter = self.downs.valueIterator();
        while (down_iter.next()) |cb_map| {
            cb_map.*.deinit();
            self.a.destroy(cb_map.*);
        }

        var up_iter = self.ups.valueIterator();
        while (up_iter.next()) |cb_map| {
            cb_map.*.deinit();
            self.a.destroy(cb_map.*);
        }

        self.downs.deinit();
        self.ups.deinit();

        self.a.destroy(self.downs);
        self.a.destroy(self.ups);
        self.a.destroy(self);
    }

    pub fn map(self: *@This(), context_id: []const u8, keys: []const Key, callback: Callback) !void {
        if (self.downs.get(context_id) == null) {
            const cb_map = try self.a.create(CallbackMap);
            cb_map.* = CallbackMap.init(self.a);
            try self.downs.put(context_id, cb_map);
        }
        if (self.ups.get(context_id) == null) {
            const cb_map = try self.a.create(CallbackMap);
            cb_map.* = CallbackMap.init(self.a);
            try self.ups.put(context_id, cb_map);
        }

        var down_map = self.downs.get(context_id) orelse unreachable;
        var up_map = self.ups.get(context_id) orelse unreachable;

        if (keys.len == 1) {
            const key_hash = hash(keys);
            if (up_map.get(key_hash) != null) {
                return up_map.put(key_hash, callback);
            }
            return down_map.put(key_hash, callback);
        }

        for (0..keys.len - 1) |i| {
            const key_chunk = keys[0 .. i + 1];
            const chunk_hash = hash(key_chunk);
            if (down_map.get(chunk_hash) != null) {
                _ = down_map.remove(chunk_hash);
                try up_map.put(chunk_hash, callback);
                continue;
            }
            if (up_map.get(chunk_hash) == null) {
                try up_map.put(chunk_hash, callback);
            }
        }
        try down_map.put(hash(keys), callback);
    }

    pub fn activate(self: *@This(), context_id: []const u8, trigger: u128) !void {
        if (self.downs.get(context_id)) |trigger_map| {
            if (trigger_map.get(trigger)) |cb| return cb.f(cb.ctx);
        }
        if (self.ups.get(context_id)) |trigger_map| {
            if (trigger_map.get(trigger)) |cb| return cb.f(cb.ctx);
        }
        std.debug.print("trigger '0x{x}' not found for context_id '{s}\n", .{ trigger, context_id });
    }

    pub fn setContextID(self: *@This(), new_context_id: []const u8) void {
        self.current_context_id = new_context_id;
    }

    pub fn produceFinalTrigger(self: *@This(), frame: *InputFrame) ?u128 {
        const r = frame.produceCandidateReport();

        if (frame.downs.items.len == 2 and
            (frame.downs.items[0].key == .left_shift or frame.downs.items[0].key == .right_shift))
        {
            return self.produceDefaultTrigger(r, frame);
        }

        if (frame.latest_event_type == .down and !r.over_threshold and self.check(.down, r.quick)) {
            if (self.downs.get(self.current_context_id).?.get(r.quick.?).?.quick) {
                frame.emitted = true;
                return r.quick;
            }
        }

        return self.produceDefaultTrigger(r, frame);
    }

    fn produceDefaultTrigger(self: *@This(), r: InputFrame.CandidateReport, frame: *InputFrame) ?u128 {
        if (frame.latest_event_type == .down) {
            frame.emitted = true;
            if (self.check(.down, r.down)) return r.down;
            if (self.check(.up, r.down)) {
                frame.emitted = false;
                frame.previous_down_candidate = r.down;
            }
            return null;
        }

        if (!frame.emitted and frame.latest_event_type == .up and self.check(.up, r.prev_down)) {
            frame.emitted = true;
            frame.previous_down_candidate = null;
            if (frame.downs.items.len == 0) frame.emitted = false;
            return r.prev_down;
        }

        return null;
    }

    fn check(self: *@This(), kind: enum { up, down }, trigger: ?u128) bool {
        if (trigger == null) return false;
        const context_map = if (kind == .up) self.ups else self.downs;
        if (context_map.get(self.current_context_id)) |trigger_map| {
            if (trigger_map.get(trigger.?)) |_| return true;
        }
        return false;
    }
};

test "MappingCouncil.map / MappingCouncil.activate" {
    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();

    const TestCtx = struct {
        value: u16 = 0,
        fn addOne(ctx_: *anyopaque) !void {
            var ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            ctx.value += 1;
        }
        fn addTen(ctx_: *anyopaque) !void {
            var ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            ctx.value += 10;
        }
    };
    var ctx = TestCtx{};
    try eq(0, ctx.value);

    try council.map("normal", &[_]Key{.a}, .{ .f = TestCtx.addOne, .ctx = &ctx });
    try council.map("normal", &[_]Key{.b}, .{ .f = TestCtx.addTen, .ctx = &ctx });

    try council.activate("normal", hash(&[_]Key{.a}));
    try eq(1, ctx.value);

    try council.activate("normal", hash(&[_]Key{.a}));
    try eq(2, ctx.value);

    try council.activate("normal", hash(&[_]Key{.b}));
    try eq(12, ctx.value);
}

test "MappingCouncil.produceTrigger" {
    const DummyCtx = struct {
        fn dummy(_: *anyopaque) !void {}
    };
    var ctx = DummyCtx{};
    const dummy_cb = Callback{ .f = DummyCtx.dummy, .ctx = &ctx };

    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();

    try council.map("normal", &[_]Key{.a}, dummy_cb);
    try council.map("normal", &[_]Key{.l}, dummy_cb);
    try council.map("normal", &[_]Key{ .l, .z }, dummy_cb);
    try council.map("normal", &[_]Key{ .l, .c }, dummy_cb);
    try council.map("normal", &[_]Key{ .l, .x }, dummy_cb);
    try council.map("normal", &[_]Key{ .l, .x, .c }, dummy_cb);

    council.setContextID("normal");

    // f12, unmapped, not prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.f12, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.a);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // a, mapped, not prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try eq(hash(&[_]Key{.a}), council.produceFinalTrigger(&frame));

        try frame.keyUp(.a);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // l, mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(hash(&[_]Key{.l}), council.produceFinalTrigger(&frame));
    }

    // l z, mapped, not prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.z, .{ .testing = 100 });
        try eq(hash(&[_]Key{ .l, .z }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // l z -> l c, both mapped, both not prefix | l mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.z, .{ .testing = 100 });
        try eq(hash(&[_]Key{ .l, .z }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.c, .{ .testing = 200 });
        try eq(hash(&[_]Key{ .l, .c }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.c);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // l f12, unmapped, not prefix | l mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.f12, .{ .testing = 100 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.f12);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    //       l f12    ->       l z
    // combo unmapped -> combo mapped
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.f12, .{ .testing = 100 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.f12);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.z, .{ .testing = 200 });
        try eq(hash(&[_]Key{ .l, .z }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // key up order doesn't matter if down trigger registered
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.z, .{ .testing = 100 });
        try eq(hash(&[_]Key{ .l, .z }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // 3 keys combo, key up order doesn't matter
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.x, .{ .testing = 100 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.c, .{ .testing = 200 });
        try eq(hash(&[_]Key{ .l, .x, .c }), council.produceFinalTrigger(&frame));

        try frame.keyDown(.c, .{ .testing = 300 });
        try eq(hash(&[_]Key{ .l, .x, .c }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.c);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // 2 keys combo, trigger on key up of 2nd key
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.x, .{ .testing = 100 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.x);
        try eq(hash(&[_]Key{ .l, .x }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // consecutive 2 keys combo, trigger on key up of 2nd key
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.x, .{ .testing = 100 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.x);
        try eq(hash(&[_]Key{ .l, .x }), council.produceFinalTrigger(&frame));

        try frame.keyDown(.x, .{ .testing = 300 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.x);
        try eq(hash(&[_]Key{ .l, .x }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.l);
        try eq(null, council.produceFinalTrigger(&frame));
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const TriggerMap = std.AutoHashMap(u128, bool);

pub const MappingVault = struct {
    a: Allocator,
    downs: struct {
        editor: TriggerMap,
        visual: TriggerMap,
        normal: TriggerMap,
        insert: TriggerMap,
        select: TriggerMap,
    },
    ups: struct {
        editor: TriggerMap,
        visual: TriggerMap,
        normal: TriggerMap,
        insert: TriggerMap,
        select: TriggerMap,
    },

    pub fn init(a: Allocator) !*MappingVault {
        const self = try a.create(MappingVault);
        self.* = MappingVault{
            .a = a,
            .downs = .{
                .editor = TriggerMap.init(a),
                .normal = TriggerMap.init(a),
                .visual = TriggerMap.init(a),
                .insert = TriggerMap.init(a),
                .select = TriggerMap.init(a),
            },
            .ups = .{
                .editor = TriggerMap.init(a),
                .normal = TriggerMap.init(a),
                .visual = TriggerMap.init(a),
                .insert = TriggerMap.init(a),
                .select = TriggerMap.init(a),
            },
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.downs.editor.deinit();
        self.downs.normal.deinit();
        self.downs.visual.deinit();
        self.downs.insert.deinit();
        self.downs.select.deinit();
        self.ups.editor.deinit();
        self.ups.normal.deinit();
        self.ups.visual.deinit();
        self.ups.insert.deinit();
        self.ups.select.deinit();
        self.a.destroy(self);
    }

    const MapError = error{OutOfMemory};

    fn map(_: *@This(), down_map: *TriggerMap, up_map: *TriggerMap, keys: []const Key) MapError!void {
        if (keys.len == 1) {
            const key_hash = hash(keys);
            if (up_map.get(key_hash) != null) {
                return up_map.put(key_hash, true);
            }
            return down_map.put(key_hash, true);
        }

        for (0..keys.len - 1) |i| {
            const key_chunk = keys[0 .. i + 1];
            const chunk_hash = hash(key_chunk);
            if (down_map.get(chunk_hash) != null) {
                _ = down_map.remove(chunk_hash);
                try up_map.put(chunk_hash, true);
                continue;
            }
            if (up_map.get(chunk_hash) == null) {
                try up_map.put(chunk_hash, false);
            }
        }
        try down_map.put(hash(keys), true);
    }

    pub fn emap(self: *@This(), keys: []const Key) MapError!void {
        try self.map(&self.downs.editor, &self.ups.editor, keys);
    }

    pub fn nmap(self: *@This(), keys: []const Key) MapError!void {
        try self.map(&self.downs.normal, &self.ups.normal, keys);
    }

    pub fn vmap(self: *@This(), keys: []const Key) MapError!void {
        try self.map(&self.downs.visual, &self.ups.visual, keys);
    }

    pub fn imap(self: *@This(), keys: []const Key) MapError!void {
        try self.map(&self.downs.insert, &self.ups.insert, keys);
    }

    pub fn smap(self: *@This(), keys: []const Key) MapError!void {
        try self.map(&self.downs.select, &self.ups.select, keys);
    }

    ///////////////////////////// Checkers

    pub fn down_checker(ctx_: *anyopaque, mode: EditorMode, trigger: ?u128) bool {
        if (trigger == null) return false;
        const cx = @as(*@This(), @ptrCast(@alignCast(ctx_)));

        const target_map = switch (mode) {
            .editor => cx.downs.editor,
            .normal => cx.downs.normal,
            .visual => cx.downs.visual,
            .insert => cx.downs.insert,
            .select => cx.downs.select,
        };

        if (target_map.get(trigger.?)) |_| return true;
        return false;
    }

    pub fn up_checker(ctx_: *anyopaque, mode: EditorMode, trigger: ?u128) bool {
        if (trigger == null) return false;
        const cx = @as(*@This(), @ptrCast(@alignCast(ctx_)));

        const target_map = switch (mode) {
            .editor => cx.ups.editor,
            .normal => cx.ups.normal,
            .visual => cx.ups.visual,
            .insert => cx.ups.insert,
            .select => cx.ups.select,
        };

        if (target_map.get(trigger.?)) |_| return true;
        return false;
    }
};

test "single down mapping gets moved to up map due to later combo mapping" {
    var v = try MappingVault.init(testing_allocator);
    defer v.deinit();

    try v.emap(&[_]Key{.a});
    try eq(true, v.downs.editor.get(hash(&[_]Key{.a})));

    try v.emap(&[_]Key{ .a, .b });
    try eq(null, v.downs.editor.get(hash(&[_]Key{.a})));
    try eq(true, v.ups.editor.get(hash(&[_]Key{.a})));
    try eq(true, v.downs.editor.get(hash(&[_]Key{ .a, .b })));
}

test "single down mapping goes straight to up map due to previous combo mapping" {
    var v = try MappingVault.init(testing_allocator);
    defer v.deinit();

    try v.emap(&[_]Key{ .a, .b });
    try eq(true, v.downs.editor.get(hash(&[_]Key{ .a, .b })));

    try v.emap(&[_]Key{.a});
    try eq(null, v.downs.editor.get(hash(&[_]Key{.a})));
}

test "map" {
    var v = try MappingVault.init(testing_allocator);
    defer v.deinit();

    try v.emap(&[_]Key{.l});
    try eq(true, v.downs.editor.get(hash(&[_]Key{.l})));

    try v.emap(&[_]Key{ .l, .z });
    try eq(null, v.downs.editor.get(hash(&[_]Key{.l})));
    try eq(true, v.ups.editor.get(hash(&[_]Key{.l})));
    try eq(true, v.downs.editor.get(hash(&[_]Key{ .l, .z })));

    try v.emap(&[_]Key{ .l, .z, .c });
    try eq(null, v.downs.editor.get(hash(&[_]Key{.l})));
    try eq(null, v.downs.editor.get(hash(&[_]Key{ .l, .z })));
    try eq(true, v.ups.editor.get(hash(&[_]Key{.l})));
    try eq(true, v.ups.editor.get(hash(&[_]Key{ .l, .z })));
    try eq(true, v.downs.editor.get(hash(&[_]Key{ .l, .z, .c })));
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const InputFrame = struct {
    const KeyDownEvent = struct { key: Key = .null, timestamp: i64 = 0 };
    const trigger_capacity = 10;

    a: Allocator,
    downs: ArrayList(KeyDownEvent),
    ups: ArrayList(KeyDownEvent),

    threshold_millis: i64 = 250,

    previous_down_candidate: ?u128 = null,
    latest_event_type: enum { up, down, none } = .none,
    emitted: bool = false,

    pub fn init(a: Allocator) !InputFrame {
        return .{
            .a = a,
            .downs = try ArrayList(KeyDownEvent).initCapacity(a, trigger_capacity),
            .ups = try ArrayList(KeyDownEvent).initCapacity(a, trigger_capacity),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.downs.deinit();
        self.ups.deinit();
    }

    const TimeStampOpttion = union(enum) { now, testing: i64 };
    pub fn keyDown(self: *@This(), key: Key, timestamp_opt: TimeStampOpttion) !void {
        for (self.downs.items) |e| if (e.key == key) return;

        self.latest_event_type = .down;
        if (self.downs.items.len >= trigger_capacity) return error.TriggerOverflow;
        const timestamp = switch (timestamp_opt) {
            .now => std.time.milliTimestamp(),
            .testing => |t| t,
        };
        try self.downs.append(.{ .key = key, .timestamp = timestamp });
    }

    pub fn keyUp(self: *@This(), key: Key) !void {
        self.latest_event_type = .up;
        var found = false;
        var index: usize = 0;
        for (self.downs.items, 0..) |e, i| {
            if (key == e.key) {
                found = true;
                index = i;
                break;
            }
        }
        if (found) {
            const removed = self.downs.orderedRemove(index);
            try self.ups.append(removed);
        }
        if (self.downs.items.len == 0) self.emitted = false;
    }

    pub fn clearKeyUps(self: *@This()) !void {
        self.ups.deinit();
        self.ups = try ArrayList(KeyDownEvent).initCapacity(self.a, trigger_capacity);
    }

    test "keyDown, keyUp, clearKeyUps" {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try eq(0, frame.downs.items.len);
        try eq(0, frame.ups.items.len);

        try frame.keyDown(.a, .{ .testing = 0 });
        try eq(1, frame.downs.items.len);
        try eq(0, frame.ups.items.len);

        try frame.keyUp(.a);
        try eq(0, frame.downs.items.len);
        try eq(1, frame.ups.items.len);

        try frame.clearKeyUps();
        try eq(0, frame.ups.items.len);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////

    fn hasDownGapsOverThreshold(self: *@This()) bool {
        if (self.downs.items.len < 2) return false;
        for (1..self.downs.items.len) |i| {
            const curr = self.downs.items[i];
            const prev = self.downs.items[i - 1];
            if (curr.timestamp - prev.timestamp > self.threshold_millis) return true;
        }
        return false;
    }

    const CandidateReport = struct {
        over_threshold: bool = false,
        quick: ?u128 = null,
        down: ?u128 = null,
        prev_down: ?u128 = null,
        prev_up: ?u128 = null,
    };

    pub fn produceCandidateReport(self: *@This()) CandidateReport {
        if (self.downs.items.len == 0) return CandidateReport{ .prev_down = self.previous_down_candidate };

        var report = CandidateReport{
            .over_threshold = self.hasDownGapsOverThreshold(),
            .prev_down = self.previous_down_candidate,
        };

        if (!report.over_threshold) {
            var hasher = KeyHasher{};
            hasher.update(self.downs.items[self.downs.items.len - 1].key);
            report.quick = hasher.value;
        }

        var hasher = KeyHasher{};
        for (self.downs.items) |e| hasher.update(e.key);
        report.down = hasher.value;

        if (!self.emitted) self.previous_down_candidate = hasher.value;

        return report;
    }

    test produceCandidateReport {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try eq(CandidateReport{
            .quick = 0x12000000000000000000000000000000,
            .down = 0x12000000000000000000000000000000,
        }, frame.produceCandidateReport());

        try frame.keyDown(.b, .{ .testing = 50 });
        try eq(CandidateReport{
            .quick = 0x13000000000000000000000000000000,
            .down = 0x12130000000000000000000000000000,
            .prev_down = 0x12000000000000000000000000000000,
        }, frame.produceCandidateReport());

        try frame.keyUp(.a);
        try eq(CandidateReport{
            .quick = 0x13000000000000000000000000000000,
            .down = 0x13000000000000000000000000000000,
            .prev_down = 0x12130000000000000000000000000000,
        }, frame.produceCandidateReport());
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EditorMode = enum { editor, normal, visual, insert, select };

const MappingChecker = *const fn (ctx: *anyopaque, mode: EditorMode, trigger: ?u128) bool;
pub fn produceTrigger(
    mode: EditorMode,
    frame: *InputFrame,
    down_ck: MappingChecker,
    up_ck: MappingChecker,
    cx: *anyopaque,
) ?u128 {
    const r = frame.produceCandidateReport();
    if (mode == .insert or mode == .select) {
        if (frame.downs.items.len == 2 and
            (frame.downs.items[0].key == .left_shift or frame.downs.items[0].key == .right_shift))
        {
            return produceDefaultTrigger(r, mode, frame, down_ck, up_ck, cx);
        }

        if (frame.latest_event_type == .down and !r.over_threshold and down_ck(cx, mode, r.quick)) {
            frame.emitted = true;
            return r.quick;
        }
    }

    return produceDefaultTrigger(r, mode, frame, down_ck, up_ck, cx);
}

fn produceDefaultTrigger(
    r: InputFrame.CandidateReport,
    mode: EditorMode,
    frame: *InputFrame,
    down_ck: MappingChecker,
    up_ck: MappingChecker,
    cx: *anyopaque,
) ?u128 {
    if (frame.latest_event_type == .down) {
        frame.emitted = true;
        if (down_ck(cx, mode, r.down)) return r.down;
        if (up_ck(cx, mode, r.down)) {
            frame.emitted = false;
            frame.previous_down_candidate = r.down;
        }
        return null;
    }
    if (!frame.emitted and frame.latest_event_type == .up and up_ck(cx, mode, r.prev_down)) {
        frame.emitted = true;
        frame.previous_down_candidate = null;
        if (frame.downs.items.len == 0) frame.emitted = false;
        return r.prev_down;
    }
    return null;
}

const Mock = struct {
    fn down_ck(_: *anyopaque, mode: EditorMode, trigger: ?u128) bool {
        if (trigger == null) return false;
        switch (mode) {
            .editor => {
                return switch (trigger.?) {
                    0x12000000000000000000000000000000 => true, // a
                    0x1d120000000000000000000000000000 => true, // l a
                    0x1d130000000000000000000000000000 => true, // l b
                    0x1d2b1400000000000000000000000000 => true, // l z c
                    else => false,
                };
            },
            .insert => {
                return switch (trigger.?) {
                    0x12000000000000000000000000000000 => true, // a
                    0x13000000000000000000000000000000 => true, // b
                    0x14000000000000000000000000000000 => true, // c
                    0x15000000000000000000000000000000 => true, // d
                    0x1d000000000000000000000000000000 => true, // l
                    0x1d120000000000000000000000000000 => true, // l a
                    else => false,
                };
            },
            else => return false,
        }
        return false;
    }
    fn up_ck(_: *anyopaque, mode: EditorMode, trigger: ?u128) bool {
        if (trigger == null) return false;
        switch (mode) {
            .editor => {
                return switch (trigger.?) {
                    0x1d000000000000000000000000000000 => true, // l
                    0x1d2b0000000000000000000000000000 => true, // l z
                    else => false,
                };
            },
            else => return false,
        }
        return false;
    }
};
fn testTrigger(expected: ?u128, mode: EditorMode, frame: *InputFrame) !void {
    var cx = Mock{};
    const result = produceTrigger(mode, frame, Mock.down_ck, Mock.up_ck, &cx);
    errdefer if (result) |value| std.debug.print("got 0x{x} instead\n", .{value});
    try eq(expected, result);
}

test "editor mode" {
    // f12 down -> f12 up
    // f12, unmapped, not prefix, single key down, then up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.f12, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.f12);
        try testTrigger(null, .editor, &frame);
    }

    // a down -> a up
    // a, mapped, not prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.a, .{ .testing = 0 });
        try testTrigger(0x12000000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .editor, &frame);
    }

    // l down -> l up
    // l, mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(0x1d000000000000000000000000000000, .editor, &frame);
    }

    // l down -> a down -> l up -> a up
    // l a, mapped, not prefix | l mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.a, .{ .testing = 200 });
        try testTrigger(0x1d120000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    // l down -> a down -> a up -> b down -> b up -> l up
    // l a -> l b, both mapped, both not prefix | l mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.a, .{ .testing = 200 });
        try testTrigger(0x1d120000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.b, .{ .testing = 400 });
        try testTrigger(0x1d130000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.b);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    // l down -> f12 down -> f12 up -> l up
    // l f12, unmapped, not prefix | l mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.f12, .{ .testing = 200 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.f12);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    //       l f12    ->       l a
    // combo unmapped -> combo mapped
    // l down -> f12 down -> f12 up -> a down -> a up -> l up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.f12, .{ .testing = 200 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.f12);
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.a, .{ .testing = 500 });
        try testTrigger(0x1d120000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    // oh no I slipeed
    // l down -> a down -> l up -> a up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.a, .{ .testing = 200 });
        try testTrigger(0x1d120000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .editor, &frame);
    }

    // three keys
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.z, .{ .testing = 200 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.c, .{ .testing = 500 });
        try testTrigger(0x1d2b1400000000000000000000000000, .editor, &frame);

        try frame.keyUp(.c);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.z);
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.z, .{ .testing = 200 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.z);
        try testTrigger(0x1d2b0000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }

    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(null, .editor, &frame);

        try frame.keyDown(.z, .{ .testing = 200 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.z);
        try testTrigger(0x1d2b0000000000000000000000000000, .editor, &frame);

        try frame.keyDown(.z, .{ .testing = 1000 });
        try testTrigger(null, .editor, &frame);

        try frame.keyUp(.z);
        try testTrigger(0x1d2b0000000000000000000000000000, .editor, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .editor, &frame);
    }
}

test "insert mode" {
    // a down -> b down -> a up -> b up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try testTrigger(0x12000000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.b, .{ .testing = 100 });
        try testTrigger(0x13000000000000000000000000000000, .insert, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .insert, &frame);

        try frame.keyUp(.b);
        try testTrigger(null, .insert, &frame);
    }

    // a down -> b down -> b up -> a up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try testTrigger(0x12000000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.b, .{ .testing = 100 });
        try testTrigger(0x13000000000000000000000000000000, .insert, &frame);

        try frame.keyUp(.b);
        try testTrigger(null, .insert, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .insert, &frame);
    }

    // mapped combo, below thresholld
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(0x1d000000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.a, .{ .testing = 100 });
        try testTrigger(0x12000000000000000000000000000000, .insert, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .insert, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .insert, &frame);
    }

    // mapped combo, above thresholld
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.l, .{ .testing = 0 });
        try testTrigger(0x1d000000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.a, .{ .testing = 500 });
        try testTrigger(0x1d120000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.a, .{ .testing = 550 });
        try testTrigger(0x1d120000000000000000000000000000, .insert, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .insert, &frame);

        try frame.keyUp(.l);
        try testTrigger(null, .insert, &frame);
    }

    // consecutive below threshold
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try testTrigger(0x12000000000000000000000000000000, .insert, &frame);

        try frame.keyDown(.a, .{ .testing = 20 });
        try testTrigger(0x12000000000000000000000000000000, .insert, &frame);

        try frame.keyUp(.a);
        try testTrigger(null, .insert, &frame);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const KeyHasher = struct {
    value: u128 = 0,
    bits_to_shift: u7 = 128 - 8,

    pub fn fromSlice(keys: []const Key) KeyHasher {
        var self = KeyHasher{};
        for (keys) |key| self.update(key);
        return self;
    }
    test fromSlice {
        const hasher = KeyHasher.fromSlice(&[_]Key{ .a, .b });
        try eq(0x12130000000000000000000000000000, hasher.value);
    }

    pub fn update(self: *@This(), key: Key) void {
        const new_part: u128 = @intCast(Key.indexOf[@intFromEnum(key)]);
        self.value |= new_part << self.bits_to_shift;
        self.bits_to_shift -= 8;
    }
    test update {
        var hasher = KeyHasher{};
        try eq(0, hasher.value);
        hasher.update(.a);
        try eq(0x12000000000000000000000000000000, hasher.value);
        hasher.update(.b);
        try eq(0x12130000000000000000000000000000, hasher.value);
    }
};

pub fn hash(keys: []const Key) u128 {
    return KeyHasher.fromSlice(keys).value;
}

const KeyEnumType = u16;
pub const Key = enum(KeyEnumType) {
    null = 0,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    zero = 48,
    one = 49,
    two = 50,
    three = 51,
    four = 52,
    five = 53,
    six = 54,
    seven = 55,
    eight = 56,
    nine = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    space = 32,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    kb_menu = 348,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave = 96,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    back = 4,
    volume_up = 24,
    key_volume_down = 25,

    const num_of_fields = std.meta.fields(Key).len;
    const index_array_len = 400;
    const indexOf = generateIndexArray();
    fn generateIndexArray() [index_array_len]u8 {
        comptime var keys = [_]u8{0} ** index_array_len;
        inline for (std.meta.fields(Key), 0..) |f, i| keys[@intCast(f.value)] = @intCast(i);
        return keys;
    }

    pub const values = generateValuesArray();
    fn generateValuesArray() [num_of_fields]KeyEnumType {
        comptime var keys = [_]KeyEnumType{0} ** num_of_fields;
        inline for (std.meta.fields(Key), 0..) |f, i| keys[i] = f.value;
        return keys;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(InputFrame);
    std.testing.refAllDeclsRecursive(KeyHasher);
}
