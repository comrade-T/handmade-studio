const std = @import("std");
const game = @import("../game.zig");

pub const InsertCharCtx = struct {
    chars: []const u8,
    pub fn callback(self: *const @This(), gs: *game.GameState) !void {
        const buf = gs.text_buffer;
        const line = 0;
        const col = 0;
        _, _, buf.root = try buf.insert_chars(buf.a, line, col, self.chars);
        gs.cached_contents.deinit();
        gs.cached_contents = try gs.text_buffer.toArrayList(gs.a);
    }
};

pub const InsertCharTriggerMap = std.StringHashMap(InsertCharCtx);
pub const InsertCharPrefixMap = std.StringHashMap(bool);

pub fn createInsertCharCallbackMap(a: std.mem.Allocator) !InsertCharTriggerMap {
    var map = std.StringHashMap(InsertCharCtx).init(a);

    const key = [_][]const u8{
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
        "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    };
    for (key) |char| try map.put(char, InsertCharCtx{ .chars = char });

    try map.put("space", InsertCharCtx{ .chars = " " });
    try map.put("tab", InsertCharCtx{ .chars = "    " });

    return map;
}
