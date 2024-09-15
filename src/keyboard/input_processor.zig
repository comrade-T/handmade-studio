const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const UpNDownContextMap = std.StringHashMap(*UpNDownCallbackMap);
const UpNDownCallbackMap = std.AutoHashMap(u128, UpNDownCallback);
pub const UpNDownCallback = struct {
    down_f: *const fn (ctx: *anyopaque) anyerror!void,
    down_ctx: *anyopaque,
    up_f: *const fn (ctx: *anyopaque) anyerror!void,
    up_ctx: *anyopaque,
};

const ContextMap = std.StringHashMap(*CallbackMap);
const CallbackMap = std.AutoHashMap(u128, Callback);
pub const Callback = struct {
    f: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,
    quick: bool = false,
};

pub const MappingCouncil = struct {
    a: Allocator,
    downs: *ContextMap,
    ups: *ContextMap,
    current_context_id: []const u8 = "",

    ups_n_downs: *UpNDownContextMap,
    pending_ups_n_downs: *ArrayList(UpNDownCallback),

    pub fn init(a: Allocator) !*@This() {
        const downs = try a.create(ContextMap);
        downs.* = ContextMap.init(a);

        const ups = try a.create(ContextMap);
        ups.* = ContextMap.init(a);

        const ups_n_downs = try a.create(UpNDownContextMap);
        ups_n_downs.* = UpNDownContextMap.init(a);

        const pending_ups_n_downs = try a.create(ArrayList(UpNDownCallback));
        pending_ups_n_downs.* = ArrayList(UpNDownCallback).init(a);

        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .downs = downs,
            .ups = ups,
            .ups_n_downs = ups_n_downs,
            .pending_ups_n_downs = pending_ups_n_downs,
        };
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

        var ups_n_downs_iter = self.ups_n_downs.valueIterator();
        while (ups_n_downs_iter.next()) |cb_map| {
            cb_map.*.deinit();
            self.a.destroy(cb_map.*);
        }

        self.downs.deinit();
        self.ups.deinit();
        self.ups_n_downs.deinit();
        self.pending_ups_n_downs.deinit();

        self.a.destroy(self.downs);
        self.a.destroy(self.ups);
        self.a.destroy(self.ups_n_downs);
        self.a.destroy(self.pending_ups_n_downs);
        self.a.destroy(self);
    }

    pub fn mapUpNDown(self: *@This(), context_id: []const u8, keys: []const Key, cb: UpNDownCallback) !void {
        if (self.ups_n_downs.get(context_id) == null) {
            const cb_map = try self.a.create(UpNDownCallbackMap);
            cb_map.* = UpNDownCallbackMap.init(self.a);
            try self.ups_n_downs.put(context_id, cb_map);
        }
        var cb_map = self.ups_n_downs.get(context_id) orelse unreachable;
        try cb_map.put(hash(keys), cb);
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
                const fetched = down_map.fetchRemove(chunk_hash);
                try up_map.put(chunk_hash, fetched.?.value);
                continue;
            }
            if (up_map.get(chunk_hash) == null) {
                try up_map.put(chunk_hash, callback);
            }
        }
        try down_map.put(hash(keys), callback);
    }

    pub fn execute(self: *@This(), frame: *InputFrame) !void {
        const report = frame.produceCandidateReport();
        const may_trigger = self.produceFinalTrigger(frame);

        if (frame.latest_event_type == .down) {
            // ups_n_downs
            if (self.ups_n_downs.get(self.current_context_id)) |trigger_map| {
                if (trigger_map.get(report.down.?)) |cb| {
                    try self.pending_ups_n_downs.append(cb);
                    try cb.down_f(cb.down_ctx);
                }
            }

            // regular
            if (self.downs.get(self.current_context_id)) |trigger_map| {
                if (may_trigger) |trigger| {
                    if (trigger_map.get(trigger)) |cb| return cb.f(cb.ctx);
                }
            }
        }

        if (frame.latest_event_type == .up) {
            // ups_n_downs
            if (frame.downs.items.len == 0) try self.cleanUpUpNDowns();

            // regular
            if (self.ups.get(self.current_context_id)) |trigger_map| {
                if (may_trigger) |trigger| {
                    if (trigger_map.get(trigger)) |cb| return cb.f(cb.ctx);
                }
            }
        }
    }

    fn cleanUpUpNDowns(self: *@This()) !void {
        for (self.pending_ups_n_downs.items) |cb| try cb.up_f(cb.up_ctx);
        self.pending_ups_n_downs.deinit();
        self.pending_ups_n_downs.* = ArrayList(UpNDownCallback).init(self.a);
    }

    pub fn setContextID(self: *@This(), new_context_id: []const u8) void {
        self.current_context_id = new_context_id;
    }

    pub fn produceFinalTrigger(self: *@This(), frame: *InputFrame) ?u128 {
        const downs = self.downs.get(self.current_context_id) orelse return null;
        const ups = self.ups.get(self.current_context_id) orelse return null;

        const r = frame.produceCandidateReport();

        if (frame.latest_event_type == .down) {
            if (frame.downs.items.len == 2 and
                (frame.downs.items[0].key == .left_shift or frame.downs.items[0].key == .right_shift))
            {
                return self.produceDefaultTrigger(r, frame);
            }

            if (frame.downs.items.len >= 2 and self.check(.down, r.down)) {
                frame.emitted = true;
                return r.down;
            }

            if (!r.over_threshold and r.quick != null) {
                var proceed = false;
                if (downs.get(r.quick.?)) |result| {
                    if (result.quick) proceed = true;
                }
                if (ups.get(r.quick.?)) |result| {
                    if (result.quick) proceed = true;
                }
                if (proceed) {
                    frame.emitted = true;
                    return r.quick;
                }
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

test "MappingCouncil.mapUpNDown()" {
    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();

    const TestCtx = struct {
        value: enum { negative, neutral, positive } = .neutral,
        fn makeNeutral(self_: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(self_)));
            self.value = .neutral;
        }
        fn makePositive(self_: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(self_)));
            self.value = .positive;
        }
        fn makeNegative(self_: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(self_)));
            self.value = .negative;
        }
    };
    var ctx = TestCtx{};
    var frame = try InputFrame.init(testing_allocator);
    defer frame.deinit();

    try council.map("normal", &[_]Key{.n}, .{ .f = TestCtx.makeNegative, .ctx = &ctx });
    try council.mapUpNDown("normal", &[_]Key{.z}, .{
        .down_f = TestCtx.makePositive,
        .down_ctx = &ctx,
        .up_f = TestCtx.makeNeutral,
        .up_ctx = &ctx,
    });

    council.setContextID("normal");
    {
        try eq(.neutral, ctx.value);

        try frame.keyDown(.n, .{ .testing = 0 });
        try council.execute(&frame);
        try eq(.negative, ctx.value);

        try frame.keyUp(.n);
        try council.execute(&frame);
        try eq(.negative, ctx.value);
    }
    {
        try eq(.negative, ctx.value);

        var timestamp: i64 = 200;
        for (0..10) |_| {
            timestamp += 10;
            try frame.keyDown(.z, .{ .testing = timestamp });
            try council.execute(&frame);
            try eq(.positive, ctx.value);
        }

        try frame.keyUp(.z);
        try council.execute(&frame);
        try eq(.neutral, ctx.value);
    }
}

// test "MappingCouncil.map with different flavor of *anyopaque ctx" {
//     var council = try MappingCouncil.init(testing_allocator);
//     defer council.deinit();
//
//     const Target = struct {
//         value: u16 = 0,
//         fn add(self: *@This(), add_by: u16) void {
//             self.value += add_by;
//         }
//     };
//     const Cb = struct {
//         add_by: u16 = 0,
//         target: *Target,
//         fn f(self_: *anyopaque) !void {
//             const self = @as(*@This(), @ptrCast(@alignCast(self_)));
//             self.target.add(self.add_by);
//         }
//         fn init(allocator: Allocator, target: *Target, add_by: u16) !Callback {
//             const self = try allocator.create(@This());
//             self.* = .{ .add_by = add_by, .target = target };
//             return Callback{ .f = @This().f, .ctx = self };
//         }
//     };
//
//     var target = Target{};
//     try eq(0, target.value);
//
//     var cb_arena = std.heap.ArenaAllocator.init(testing_allocator);
//     defer cb_arena.deinit();
//     const a = cb_arena.allocator();
//
//     try council.map("normal", &[_]Key{.a}, try Cb.init(a, &target, 1));
//     try council.map("normal", &[_]Key{.b}, try Cb.init(a, &target, 10));
//
//     council.setContextID("normal");
//
//     try council.activate(hash(&[_]Key{.a}));
//     try eq(1, target.value);
//
//     try council.activate(hash(&[_]Key{.a}));
//     try eq(2, target.value);
//
//     try council.activate(hash(&[_]Key{.b}));
//     try eq(12, target.value);
// }

const DummyCtx = struct {
    fn dummy(_: *anyopaque) !void {}
};

test "MappingCouncil.produceTrigger - quick" {
    var ctx = DummyCtx{};
    const quick_cb = Callback{ .f = DummyCtx.dummy, .ctx = &ctx, .quick = true };
    const dummy_cb = Callback{ .f = DummyCtx.dummy, .ctx = &ctx };

    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();

    try council.map("insert", &[_]Key{.a}, quick_cb);
    try council.map("insert", &[_]Key{.b}, quick_cb);
    try council.map("insert", &[_]Key{.z}, dummy_cb);
    try council.map("insert", &[_]Key{ .z, .a }, dummy_cb);

    council.setContextID("insert");

    // a down -> b down -> a up -> b up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try eq(hash(&[_]Key{.a}), council.produceFinalTrigger(&frame));

        try frame.keyDown(.b, .{ .testing = 100 });
        try eq(hash(&[_]Key{.b}), council.produceFinalTrigger(&frame));

        try frame.keyUp(.a);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.b);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // a down -> b down -> b up -> a up
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a, .{ .testing = 0 });
        try eq(hash(&[_]Key{.a}), council.produceFinalTrigger(&frame));

        try frame.keyDown(.b, .{ .testing = 100 });
        try eq(hash(&[_]Key{.b}), council.produceFinalTrigger(&frame));

        try frame.keyUp(.b);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.a);
        try eq(null, council.produceFinalTrigger(&frame));
    }

    // z, mapped, is prefix
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.z, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(hash(&[_]Key{.z}), council.produceFinalTrigger(&frame));
    }

    // z a, mapped combo
    {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.z, .{ .testing = 0 });
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyDown(.a, .{ .testing = 100 });
        try eq(hash(&[_]Key{ .z, .a }), council.produceFinalTrigger(&frame));

        try frame.keyUp(.z);
        try eq(null, council.produceFinalTrigger(&frame));

        try frame.keyUp(.a);
        try eq(null, council.produceFinalTrigger(&frame));
    }
}

test "MappingCouncil.produceTrigger - non-quick" {
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

    mouse_button_left = mouse_code_offset + 0,
    mouse_button_right = mouse_code_offset + 1,
    mouse_button_middle = mouse_code_offset + 2,
    mouse_button_side = mouse_code_offset + 3,
    mouse_button_extra = mouse_code_offset + 4,
    mouse_button_forward = mouse_code_offset + 5,
    mouse_button_back = mouse_code_offset + 6,
    pub const mouse_code_offset = 360;

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
