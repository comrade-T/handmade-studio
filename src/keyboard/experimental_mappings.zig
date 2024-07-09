const std = @import("std");

pub const letters_and_numbers = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
};

pub const ExperimentalTriggerMap = std.StringHashMap(bool);
pub const ExperimentalPrefixMap = std.StringHashMap(bool);

pub fn createInsertCharTriggerMap(a: std.mem.Allocator) !ExperimentalTriggerMap {
    var map = ExperimentalTriggerMap.init(a);

    for (letters_and_numbers) |char| try map.put(char, true);

    const other_keys = [_][]const u8{
        "space",     "tab",    "enter", "up",  "down", "left", "right",
        "backspace", "delete", "home",  "end",
    };
    for (other_keys) |trigger| try map.put(trigger, true);

    return map;
}
