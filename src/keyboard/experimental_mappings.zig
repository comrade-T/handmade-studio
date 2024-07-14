const std = @import("std");

pub const letters_and_numbers = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
};
pub const single_char_symbols = [_][]const u8{
    "=", "-", "[", "]", "\\",
    ";", "'", ",", ".", "/",
};
pub const other_mappings = [_][]const []const u8{
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

    for (letters_and_numbers) |char| try map.put(char, .{ .insert = char });
    for (single_char_symbols) |char| try map.put(char, .{ .insert = char });
    for (other_mappings) |mapping| try map.put(mapping[0], .{ .insert = mapping[1] });

    const other_keys = [_][]const u8{
        "up",        "down",   "left", "right",
        "backspace", "delete", "home", "end",
    };
    for (other_keys) |trigger| try map.put(trigger, .{ .custom = true });

    try map.put("s o", .{ .custom = true });

    return map;
}

pub fn createPrefixMap(a: std.mem.Allocator) !PrefixMap {
    var map = PrefixMap.init(a);

    try map.put("s", true);

    return map;
}
