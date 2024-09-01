const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const KeyboardTrigger = struct {
    const KeyDownEvent = struct { key: Key = .null, timestamp: i64 = 0 };
    const cap = 10;

    arr: [cap]KeyDownEvent = [_]KeyDownEvent{.{}} ** cap,
    len: usize = 0,

    const AppendEventError = error{ReachedMaxCap};
    pub fn addEvent(self: *@This(), e: KeyDownEvent) AppendEventError!void {
        if (self.len == cap) return AppendEventError.ReachedMaxCap;
        self.arr[self.len] = e;
        self.len += 1;
    }
    test addEvent {
        var state = KeyboardTrigger{};
        try state.addEvent(KeyDownEvent{ .key = .a, .timestamp = 100 });
        try eq(1, state.len);
        try eq(KeyDownEvent{ .key = .a, .timestamp = 100 }, state.arr[0]);
    }

    fn removeEvent(self: *@This(), key: Key) void {
        if (key == .null) return;
        var found = false;
        for (self.arr, 0..) |e, i| {
            if (key == e.key) {
                found = true;
                continue;
            }
            if (!found) continue;
            if (found) self.arr[i - 1] = e;
        }
        self.arr[cap - 1] = KeyDownEvent{};
        if (found) self.len -= 1;
    }
    test removeEvent {
        var state = KeyboardTrigger{};
        try state.addEvent(KeyDownEvent{ .key = .a, .timestamp = 100 });
        state.removeEvent(.a);
        try eq(0, state.len);
    }
};

test KeyboardTrigger {
    const state = KeyboardTrigger{};
    try eq(10, state.arr.len);
    try eq(0, state.len);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Key = enum(c_int) {
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
    std.testing.refAllDeclsRecursive(KeyboardTrigger);
}
