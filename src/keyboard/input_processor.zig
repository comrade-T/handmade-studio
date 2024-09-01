const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const InputFrame = struct {
    const KeyDownEvent = struct { key: Key = .null, timestamp: i64 = 0 };
    const capacity = 10;

    a: Allocator,
    downs: ArrayList(KeyDownEvent),
    ups: ArrayList(KeyDownEvent),

    pub fn init(a: Allocator) !InputFrame {
        return .{
            .a = a,
            .downs = try ArrayList(KeyDownEvent).initCapacity(a, capacity),
            .ups = try ArrayList(KeyDownEvent).initCapacity(a, capacity),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.downs.deinit();
        self.ups.deinit();
    }

    pub fn keyDown(self: *@This(), key: Key) !void {
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
        self.ups = try ArrayList(KeyDownEvent).initCapacity(self.a, capacity);
    }

    fn hash(self: *@This()) u32 {
        var hasher = KeyHasher_32.init();
        for (self.downs.items) |e| hasher.update(e.key);
        return hasher.final();
    }
    test hash {
        var frame = try InputFrame.init(testing_allocator);
        defer frame.deinit();

        try frame.keyDown(.a);
        try eq(0xc40bf6cc, frame.hash());

        try frame.keyUp(.a);
        try eq(0x811c9dc5, frame.hash());
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

pub const KeyHasher_32 = KeyHasher(u32, 0x01000193, 0x811c9dc5);
pub const KeyHasher_64 = KeyHasher(u64, 0x100000001b3, 0xcbf29ce484222325);
pub const KeyHasher_128 = KeyHasher(u128, 0x1000000000000000000013b, 0x6c62272e07bb014262b821756295c58d);

fn KeyHasher(comptime T: type, comptime prime: T, comptime offset: T) type {
    return struct {
        value: T,

        pub fn init() @This() {
            return @This(){ .value = offset };
        }

        pub fn update(self: *@This(), key: Key) void {
            self.value ^= @intFromEnum(key);
            self.value *%= prime;
        }

        pub fn final(self: *@This()) T {
            return self.value;
        }
    };
}

const Key = enum(u16) {
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
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(InputFrame);
}
