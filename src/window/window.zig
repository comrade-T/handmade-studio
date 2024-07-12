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
};

test Window {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    var window = try Window.create(a, ziglang);
    defer window.deinit();

    window.cursor.up(100);
    try eq(0, window.cursor.line);
}