const std = @import("std");

pub const letters_and_numbers = [_][]const u8{
    "a", "b",  "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o",  "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "1", "2",  "3", "4", "5", "6", "7", "8", "9", "0", "=", "-", "[",
    "]", "\\", ";", "'", ",", ".", "/",
};
pub const letters_and_numbers_upper = [_][]const u8{
    "A", "B", "C", "D",  "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q",  "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "!", "@", "#", "$",  "%", "^", "&", "*", "(", ")", "+", "_", "{",
    "}", "|", ":", "\"", "<", ">", "?",
};
pub const other_inserts = [_][]const []const u8{
    &[_][]const u8{ "space", " " },
    &[_][]const u8{ "tab", "    " },
    &[_][]const u8{ "enter", "\n" },
};

pub const TriggerAction = union(enum) {
    insert: []const u8,
    custom: bool,
};

pub const TriggerMap = std.StringHashMap(TriggerAction);
pub const PrefixMap = std.StringHashMap(bool);

pub fn createTriggerMap(a: std.mem.Allocator) !TriggerMap {
    var map = TriggerMap.init(a);

    {
        comptime var lshift_triggers = [_][]const u8{undefined} ** letters_and_numbers.len;
        comptime var rshift_triggers = [_][]const u8{undefined} ** letters_and_numbers.len;
        comptime var lctrl_triggers = [_][]const u8{undefined} ** letters_and_numbers.len;
        comptime var rctrl_triggers = [_][]const u8{undefined} ** letters_and_numbers.len;
        inline for (letters_and_numbers, 0..) |char, i| lshift_triggers[i] = "lshift " ++ char;
        inline for (letters_and_numbers, 0..) |char, i| rshift_triggers[i] = "rshift " ++ char;
        inline for (letters_and_numbers, 0..) |char, i| lctrl_triggers[i] = "lctrl " ++ char;
        inline for (letters_and_numbers, 0..) |char, i| rctrl_triggers[i] = "rctrl " ++ char;

        for (letters_and_numbers) |char| try map.put(char, .{ .insert = char });
        for (letters_and_numbers_upper, 0..) |char, i| try map.put(lshift_triggers[i], .{ .insert = char });
        for (letters_and_numbers_upper, 0..) |char, i| try map.put(rshift_triggers[i], .{ .insert = char });

        for (letters_and_numbers_upper, 0..) |_, i| try map.put(lctrl_triggers[i], .{ .custom = true });
        for (letters_and_numbers_upper, 0..) |_, i| try map.put(rctrl_triggers[i], .{ .custom = true });
    }

    for (other_inserts) |mapping| try map.put(mapping[0], .{ .insert = mapping[1] });

    const custom_keys = [_][]const u8{
        "up",        "down",   "left", "right",
        "backspace", "delete", "home", "end",
    };
    for (custom_keys) |trigger| try map.put(trigger, .{ .custom = true });

    try map.put("s o", .{ .custom = true });

    try map.put("w h", .{ .custom = true });
    try map.put("w l", .{ .custom = true });

    return map;
}

pub fn createPrefixMap(a: std.mem.Allocator) !PrefixMap {
    var map = PrefixMap.init(a);

    try map.put("s", true);
    try map.put("w", true);
    try map.put("lshift", true);
    try map.put("rshift", true);
    try map.put("lctrl", true);

    return map;
}
