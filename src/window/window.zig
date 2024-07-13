const std = @import("std");
const ts_ = @import("ts");
const ts = ts_.b;
const PredicatesFilter = ts_.PredicatesFilter;
const Buffer = @import("buffer").Buffer;
const Cursor = @import("cursor").Cursor;

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const Window = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,

    buffer: *Buffer,
    cursor: Cursor,

    string_buffer: std.ArrayList(u8),

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

            .string_buffer = std.ArrayList(u8).init(self.a),

            .parser = try ts.Parser.create(),
            .tree = undefined,
        };

        self.buffer.root = try self.buffer.load_from_string("");

        try self.parser.setLanguage(lang);
        self.tree = try self.parser.parseString(null, "");

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.parser.destroy();
        self.tree.destroy();
        self.string_buffer.deinit();
        self.buffer.deinit();
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    pub fn insertChars(self: *@This(), chars: []const u8) !void {
        const start_line = self.cursor.line;
        const start_col = self.cursor.col;

        const start_point = ts.Point{ .row = @intCast(start_line), .column = @intCast(start_col) };
        const old_end_point = start_point;

        const start_byte = try self.buffer.getByteOffsetAtPoint(start_line, start_col);
        const old_end_byte = start_byte;

        /////////////////////////////

        const end_line, const end_col = try self.buffer.insertCharsAndUpdate(start_line, start_col, chars);
        const new_end_point = ts.Point{ .row = @intCast(end_line), .column = @intCast(end_col) };
        const new_end_byte = start_byte + chars.len;

        /////////////////////////////

        const old_string_buffer = self.string_buffer;
        defer old_string_buffer.deinit();
        self.string_buffer = try self.buffer.toArrayList(self.a);

        /////////////////////////////

        self.cursor.set(end_line, end_col);

        /////////////////////////////

        const edit = ts.InputEdit{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = new_end_point,
        };
        self.tree.edit(&edit);

        const old_tree = self.tree;
        defer old_tree.destroy();
        self.tree = try self.parser.parseString(old_tree, self.string_buffer.items);
    }
};

const patterns =
    \\[
    \\  "const"
    \\  "var"
    \\] @type.qualifier
    \\
    \\((IDENTIFIER) @std_identifier
    \\  (#eq? @std_identifier "std"))
    \\
    \\((BUILTINIDENTIFIER) @include
    \\  (#any-of? @include "@import" "@cImport"))
;

fn testWindowTreeHasMatches(
    window: *const Window,
    query: *ts.Query,
    filter: *PredicatesFilter,
    comparisons: []const []const []const u8,
) !void {
    const source = window.string_buffer.items;
    const cursor = try ts.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(query, window.tree.getRootNode());

    var i: usize = 0;
    while (filter.nextMatch(source, cursor)) |pattern| {
        for (pattern.captures(), 0..) |capture, j| {
            const node = capture.node;
            try eqStr(comparisons[i][j], source[node.getStartByte()..node.getEndByte()]);
        }
        i += 1;
    }
    try eq(comparisons.len, i);
}

test "Window.insertChars()" {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    var window = try Window.create(a, ziglang);
    defer window.deinit();

    const query = try ts.Query.create(ziglang, patterns);
    defer query.destroy();
    var filter = try PredicatesFilter.init(a, query);
    defer filter.deinit();

    /////////////////////////////

    try eqStr("", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{});

    try window.insertChars("c");
    try eqStr("c", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{});

    try window.insertChars("onst");
    try eqStr("const", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
        &[_][]const u8{"const"},
    });

    try window.insertChars(" std");
    try eqStr("const std", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
        &[_][]const u8{"const"},
        &[_][]const u8{"std"},
    });

    try window.insertChars(" = @import(\"");
    try eqStr("const std = @import(\"", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
        &[_][]const u8{"const"},
        &[_][]const u8{"std"},
        &[_][]const u8{"@import"},
    });

    try window.insertChars("std\");");
    try eqStr("const std = @import(\"std\");", window.string_buffer.items);
    try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
        &[_][]const u8{"const"},
        &[_][]const u8{"std"},
        &[_][]const u8{"@import"},
    });
}
