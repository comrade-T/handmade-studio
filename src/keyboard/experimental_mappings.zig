const std = @import("std");
const game = @import("../game.zig");

const eql = std.mem.eql;

pub const letters_and_numbers = [_][]const u8{
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
};

fn insert_chars(gs: *game.GameState, chars: []const u8) !void {
    const buf = gs.text_buffer;
    _, _, buf.root = try buf.insert_chars(buf.a, gs.cursor.line, gs.cursor.col, chars);

    gs.cached_contents.deinit();
    gs.cached_contents = try gs.text_buffer.toArrayList(gs.a);

    if (eql(u8, chars, "\n")) {
        const line = gs.cursor.line + 1;
        const col = 0;
        gs.cursor.set(line, col);
        return;
    }
    gs.cursor.right(1, try gs.text_buffer.num_of_chars_in_line(gs.cursor.line));
}

pub const ExperimentalCallbackCtx = struct {
    trigger: []const u8,

    pub fn callback(self: *const @This(), gs: *game.GameState) !void {
        if (self.trigger.len == 1)
            for (letters_and_numbers) |chars|
                if (eql(u8, chars, self.trigger))
                    return try insert_chars(gs, chars);

        if (eql(u8, self.trigger, "space")) return try insert_chars(gs, " ");
        if (eql(u8, self.trigger, "tab")) return try insert_chars(gs, "    ");

        if (eql(u8, self.trigger, "enter")) {
            return try insert_chars(gs, "\n");
        }

        if (eql(u8, self.trigger, "up")) gs.cursor.up(1);
        if (eql(u8, self.trigger, "left")) gs.cursor.left(1);
        if (eql(u8, self.trigger, "down")) {
            gs.cursor.down(1, gs.text_buffer.num_of_lines());
            return;
        }
        if (eql(u8, self.trigger, "right")) {
            const line_width = try gs.text_buffer.num_of_chars_in_line(gs.cursor.line);
            gs.cursor.right(1, line_width);
            return;
        }

        if (eql(u8, self.trigger, "backspace")) {
            gs.text_buffer.root = try gs.text_buffer.delete_chars(gs.text_buffer.a, gs.cursor.line, gs.cursor.col -| 1, 1);

            gs.cached_contents.deinit();
            gs.cached_contents = try gs.text_buffer.toArrayList(gs.a);

            gs.cursor.left(1);
        }
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

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
