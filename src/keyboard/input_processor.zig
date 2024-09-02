const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

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
        defer {
            if (self.downs.items.len == 0) self.emitted = false;
        }
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

const EditorMode = enum { editor, normal, visual, insert, select };

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
    if (up_ck(cx, mode, r.down)) return null;
    if (frame.latest_event_type == .down and down_ck(cx, mode, r.down)) {
        frame.emitted = true;
        return r.down;
    }
    if (!frame.emitted and frame.latest_event_type == .up and up_ck(cx, mode, r.prev_down)) {
        frame.emitted = true;
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
                    else => false,
                };
            },
            .insert => {
                return switch (trigger.?) {
                    0x12000000000000000000000000000000 => true, // a
                    0x13000000000000000000000000000000 => true, // b
                    0x14000000000000000000000000000000 => true, // c
                    0x15000000000000000000000000000000 => true, // d
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
        try testTrigger(0x1d000000000000000000000000000000, .editor, &frame);
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
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const KeyHasher = struct {
    value: u128 = 0,
    bits_to_shift: u7 = 128 - 8,

    fn fromSlice(keys: []const Key) KeyHasher {
        var self = KeyHasher{};
        for (keys) |key| self.update(key);
        return self;
    }
    test fromSlice {
        const hasher = KeyHasher.fromSlice(&[_]Key{ .a, .b });
        try eq(0x12130000000000000000000000000000, hasher.value);
    }

    fn update(self: *@This(), key: Key) void {
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

const KeyEnumType = u16;
const Key = enum(KeyEnumType) {
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
    const lookup_array_len = 400;
    const indexOf = generateLookUpArray();
    fn generateLookUpArray() [lookup_array_len]u8 {
        comptime var keys = [_]u8{0} ** lookup_array_len;
        inline for (std.meta.fields(Key), 0..) |f, i| keys[@intCast(f.value)] = @intCast(i);
        return keys;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(InputFrame);
    std.testing.refAllDeclsRecursive(KeyHasher);
}
