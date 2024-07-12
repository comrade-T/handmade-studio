const std = @import("std");
const ts = @import("ts").b;
const Buffer = @import("buffer").Buffer;
const Cursor = @import("cursor").Cursor;

const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const Window = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,

    buffer: *Buffer,
    cursor: Cursor,

    parser: *ts.Parser,
    tree: *ts.Tree,

    pub fn create(external_allocator: Allocator, lang: *const ts.Language) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),

            .buffer = try Buffer.create(self.a, self.a),
            .cursor = Cursor{},

            .parser = try ts.Parser.create(),
            .tree = undefined,
        };

        try self.parser.setLanguage(lang);
        self.tree = try self.parser.parseString(null, "");

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.parser.destroy();
        self.tree.destroy();
        self.buffer.deinit();
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    pub fn insertChars(self: *@This(), line: usize, col: usize, chars: []const u8) !void {
        const new_line, const new_col = self.buffer.insertCharsAndUpdate(self.buffer.a, line, col, chars);

        const edit = ts.InputEdit{
            .start_byte = 0, // how??? how do I get the byte offset?
            .old_end_byte = 0, // how??? how do I get the byte offset?
            .new_end_byte = 0, // how??? how do I get the byte offset?
            .start_point = ts.Point{ .row = self.cursor.line, .column = self.cursor.col },
            .old_end_point = ts.Point{ .row = line, .column = col },
            .new_end_point = ts.Point{ .row = new_line, .column = new_col },
        };
        self.tree.edit(edit);
    }
};

test Window {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    var window = try Window.create(a, ziglang);
    defer window.deinit();

    window.cursor.up(100);
    try eq(0, window.cursor.line);
}
