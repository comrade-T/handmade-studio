const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const game = @import("../game.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EventArray = [400]bool;
pub const EventList = std.ArrayList(c_int);

pub fn updateEventList(arr: *EventArray, list: *EventList) !void {
    for (list.items, 0..) |code, i| {
        if (r.IsKeyUp(code)) {
            _ = list.orderedRemove(i);
            arr[@intCast(code)] = false;
        }
    }
    for (supported_key_codes) |code| {
        if (r.IsKeyDown(code)) {
            if (arr[@intCast(code)]) continue;
            try list.append(code);
            arr[@intCast(code)] = true;
        }
    }
}

fn eventListToStr(allocator: std.mem.Allocator, e_list: *EventList) ![]const u8 {
    var str_list = std.ArrayList(u8).init(allocator);
    errdefer str_list.deinit();
    for (e_list.items, 0..) |code, i| {
        const str = getStringRepresentationOfKeyCode(code);
        if (i > 0) try str_list.appendSlice(" ");
        try str_list.appendSlice(str);
    }
    return str_list.toOwnedSlice();
}

test "eventListToStr" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(c_int).init(allocator);
    defer list.deinit();
    try list.append(r.KEY_D);
    try list.append(r.KEY_J);
    const result = try eventListToStr(allocator, &list);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("d j", result);
}

pub fn printEventList(allocator: std.mem.Allocator, list: *EventList) !void {
    const str = try eventListToStr(allocator, list);
    defer allocator.free(str);
    std.debug.print("{s}\n", .{str});
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn mayInvokeKeyUp(old: []c_int, new: []c_int) bool {
    if (old.len < new.len) return false;
    for (0..new.len) |i| if (old[i] != new[i]) return false;
    return true;
}

test mayInvokeKeyUp {
    var old1 = [_]c_int{ 1, 2, 3 };
    var new1 = [_]c_int{ 1, 2 };
    try std.testing.expect(mayInvokeKeyUp(&old1, &new1));

    var old2 = [_]c_int{ 1, 2, 3 };
    var new2 = [_]c_int{ 1, 2, 3, 4 };
    try std.testing.expect(!mayInvokeKeyUp(&old2, &new2));

    var old3 = [_]c_int{ 1, 2, 3 };
    var new3 = [_]c_int{1};
    try std.testing.expect(mayInvokeKeyUp(&old3, &new3));

    var old4 = [_]c_int{ 1, 2, 3 };
    var new4 = [_]c_int{ 2, 3 };
    try std.testing.expect(!mayInvokeKeyUp(&old4, &new4));
}

//////////////////////////////////////////////////////////////////////////////////////////////

const supported_key_codes = [_]c_int{
    r.KEY_A,
    r.KEY_B,
    r.KEY_C,
    r.KEY_D,
    r.KEY_E,
    r.KEY_F,
    r.KEY_G,
    r.KEY_H,
    r.KEY_I,
    r.KEY_J,
    r.KEY_K,
    r.KEY_L,
    r.KEY_M,
    r.KEY_N,
    r.KEY_O,
    r.KEY_P,
    r.KEY_Q,
    r.KEY_R,
    r.KEY_S,
    r.KEY_T,
    r.KEY_U,
    r.KEY_V,
    r.KEY_W,
    r.KEY_X,
    r.KEY_Y,
    r.KEY_Z,

    r.KEY_ONE,
    r.KEY_TWO,
    r.KEY_THREE,
    r.KEY_FOUR,
    r.KEY_FIVE,
    r.KEY_SIX,
    r.KEY_SEVEN,
    r.KEY_EIGHT,
    r.KEY_NINE,
    r.KEY_ZERO,

    r.KEY_F1,
    r.KEY_F2,
    r.KEY_F3,
    r.KEY_F4,
    r.KEY_F5,
    r.KEY_F6,
    r.KEY_F7,
    r.KEY_F8,
    r.KEY_F9,
    r.KEY_F10,
    r.KEY_F11,
    r.KEY_F12,

    r.KEY_ENTER,
    r.KEY_SPACE,
    // ...
};

fn getStringRepresentationOfKeyCode(c: c_int) []const u8 {
    return switch (c) {
        r.KEY_A => "a",
        r.KEY_B => "b",
        r.KEY_C => "c",
        r.KEY_D => "d",
        r.KEY_E => "e",
        r.KEY_F => "f",
        r.KEY_G => "g",
        r.KEY_H => "h",
        r.KEY_I => "i",
        r.KEY_J => "j",
        r.KEY_K => "k",
        r.KEY_L => "l",
        r.KEY_M => "m",
        r.KEY_N => "n",
        r.KEY_O => "o",
        r.KEY_P => "p",
        r.KEY_Q => "q",
        r.KEY_R => "r",
        r.KEY_S => "s",
        r.KEY_T => "t",
        r.KEY_U => "u",
        r.KEY_V => "v",
        r.KEY_W => "w",
        r.KEY_X => "x",
        r.KEY_Y => "y",
        r.KEY_Z => "z",

        r.KEY_ONE => "1",
        r.KEY_TWO => "2",
        r.KEY_THREE => "3",
        r.KEY_FOUR => "4",
        r.KEY_FIVE => "5",
        r.KEY_SIX => "6",
        r.KEY_SEVEN => "7",
        r.KEY_EIGHT => "8",
        r.KEY_NINE => "9",
        r.KEY_ZERO => "0",

        r.KEY_F1 => "<F1>",
        r.KEY_F2 => "<F2>",
        r.KEY_F3 => "<F3>",
        r.KEY_F4 => "<F4>",
        r.KEY_F5 => "<F5>",
        r.KEY_F6 => "<F6>",
        r.KEY_F7 => "<F7>",
        r.KEY_F8 => "<F8>",
        r.KEY_F9 => "<F9>",
        r.KEY_F10 => "<F10>",
        r.KEY_F11 => "<F11>",
        r.KEY_F12 => "<F12>",

        else => "",
    };
}
