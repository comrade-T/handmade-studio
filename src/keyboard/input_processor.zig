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

    pub fn keyDown(self: *@This(), key: Key) !void {
        if (self.downs.items.len >= trigger_capacity) return error.TriggerOverflow;
        try self.downs.append(.{ .key = key, .timestamp = std.time.microTimestamp() });
    }

    pub fn keyUp(self: *@This(), key: Key) !void {
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

    //////////////////////////////////////////////////////////////////////////////////////////////

    const CandidateReport = struct {
        over_threshold: bool = false,
        quick_cut_candidate: ?u128 = null,
        down_candidate: ?u128 = null,
        up_candidate: ?u128 = null,
    };

    const threshold_micro = 250_000;
    fn hasDownGapsOverThreshold(self: *@This()) bool {
        if (self.downs.items.len < 2) return false;
        for (1..self.downs.items.len) |i| {
            const curr = self.downs.items[i];
            const prev = self.downs.items[i - 1];
            if (curr.timestamp - prev.timestamp > threshold_micro) return true;
        }
        return false;
    }

    pub fn produceCandidateReport(self: *@This()) CandidateReport {
        if (self.downs.items.len == 0) return CandidateReport{};

        var result = CandidateReport{ .over_threshold = self.hasDownGapsOverThreshold() };

        if (!result.over_threshold) {
            var hasher = KeyHasher{};
            hasher.update(self.downs.items[self.downs.items.len - 1].key);
            result.quick_cut_candidate = hasher.value;
        }

        var hasher = KeyHasher{};
        for (self.downs.items) |e| hasher.update(e.key);
        result.down_candidate = hasher.value;

        for (self.ups.items) |e| hasher.update(e.key);
        result.up_candidate = hasher.value;

        return result;
    }
};

test InputFrame {
    var frame = try InputFrame.init(testing_allocator);
    defer frame.deinit();

    try eq(0, frame.downs.items.len);
    try eq(0, frame.ups.items.len);

    try frame.keyDown(.a);
    try eq(1, frame.downs.items.len);
    try eq(0, frame.ups.items.len);

    try frame.keyUp(.a);
    try eq(0, frame.downs.items.len);
    try eq(1, frame.ups.items.len);

    try frame.clearKeyUps();
    try eq(0, frame.ups.items.len);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const KeyHasher = struct {
    value: u128 = 0,
    bits_to_shift: u7 = 128 - 8,

    fn update(self: *@This(), key: Key) void {
        const new_part: u128 = @intCast(Key.indexOf[@intFromEnum(key)]);
        self.value |= new_part << self.bits_to_shift;
        self.bits_to_shift -= 8;
    }

    test KeyHasher {
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