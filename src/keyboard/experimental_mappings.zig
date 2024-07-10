const std = @import("std");

pub const letters_and_numbers = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
};

pub const TriggerMap = std.StringHashMap(bool);
pub const PrefixMap = std.StringHashMap(bool);

pub fn createTriggerMap(a: std.mem.Allocator) !TriggerMap {
    var map = TriggerMap.init(a);

    for (letters_and_numbers) |char| try map.put(char, true);

    const other_keys = [_][]const u8{
        "space",     "tab",    "enter", "up",  "down", "left", "right",
        "backspace", "delete", "home",  "end",
    };
    for (other_keys) |trigger| try map.put(trigger, true);

    try map.put("s o", true);

    return map;
}

pub fn createPrefixMap(a: std.mem.Allocator) !PrefixMap {
    var map = PrefixMap.init(a);

    try map.put("s", true);

    return map;
}
