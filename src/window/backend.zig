const std = @import("std");
const rl = @import("raylib");
const Color = rl.Color;
const ts_ = @import("ts");
pub const ts = ts_.b;
const PredicatesFilter = ts_.PredicatesFilter;
const _b = @import("buffer");
const Buffer = _b.Buffer;
const Cursor = @import("cursor.zig").Cursor;

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const WindowBackend = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,

    buffer: *Buffer,
    cursor: Cursor,

    string_buffer: std.ArrayList(u8),

    cells: std.ArrayList(Cell),
    lines: std.ArrayList(Line),

    parser: ?*ts.Parser = null,
    tree: ?*ts.Tree = null,

    highlight_query: ?*ts.Query = null,
    highlight_filter: ?*PredicatesFilter = null,
    highlight_map: ?HighlightMap = null,

    pub fn create(external_allocator: Allocator) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),

            .buffer = try Buffer.create(self.a, self.a),
            .cursor = Cursor{},

            .string_buffer = std.ArrayList(u8).init(self.a),

            .cells = std.ArrayList(Cell).init(self.a),
            .lines = std.ArrayList(Line).init(self.a),
        };

        self.buffer.root = try self.buffer.load_from_string("");

        return self;
    }

    pub fn createWithTreeSitter(external_allocator: Allocator, lang: *const ts.Language, patterns: []const u8) !*WindowBackend {
        var self = try WindowBackend.create(external_allocator);
        try self.initializeTreeSitter(lang, patterns);
        return self;
    }

    pub fn initializeTreeSitter(self: *@This(), lang: *const ts.Language, patterns: []const u8) !void {
        self.parser = try ts.Parser.create();
        try self.parser.?.setLanguage(lang);
        self.highlight_query = try ts.Query.create(lang, patterns);
        self.highlight_filter = try PredicatesFilter.init(self.a, self.highlight_query.?);
        self.highlight_map = try createExperimentalHighlightMap(self.a);
        self.tree = try self.parser.?.parseString(null, self.string_buffer.items);
    }

    pub fn deinit(self: *@This()) void {
        if (self.parser) |_| self.parser.?.destroy();
        if (self.tree) |_| self.tree.?.destroy();

        if (self.highlight_query) |_| self.highlight_query.?.destroy();
        if (self.highlight_filter) |_| self.highlight_filter.?.deinit();
        if (self.highlight_map) |_| self.highlight_map.?.deinit();

        self.string_buffer.deinit();
        self.buffer.deinit();
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    pub fn deleteCharsBackwards(self: *@This(), count: usize) !void {
        const start_line = self.cursor.line;
        const start_col = self.cursor.col;
        const start_point = ts.Point{ .row = @intCast(start_line), .column = @intCast(start_col) };
        const start_byte = try self.buffer.getByteOffsetAtPoint(start_line, start_col);

        /////////////////////////////

        const char_count_till_start = _b.num_of_chars(self.string_buffer.items[0..start_byte]);
        const char_count_till_end = char_count_till_start -| count;
        const num_of_bytes_to_delete = _b.byte_count_for_range(self.string_buffer.items, char_count_till_end, char_count_till_start);
        const new_end_byte = start_byte - num_of_bytes_to_delete;

        var end_line = start_line;
        var end_col = start_col;
        {
            var char_list = std.ArrayList(u21).init(self.a);
            defer char_list.deinit();

            var iter = _b.code_point.Iterator{ .bytes = self.string_buffer.items[new_end_byte..start_byte] };
            while (iter.next()) |cp| try char_list.append(cp.code);

            var i: usize = char_list.items.len;
            while (i > 0) {
                i -= 1;
                end_col -|= 1;
                if (char_list.items[i] == @as(u21, '\n')) {
                    end_line -|= 1;
                    end_col = try self.buffer.num_of_chars_in_line(end_line);
                }
            }
        }
        const new_end_point = ts.Point{ .row = @intCast(end_line), .column = @intCast(end_col) };

        /////////////////////////////

        const num_of_chars_to_delete = _b.num_of_chars(self.string_buffer.items[new_end_byte..start_byte]);
        try self.buffer.deleteCharsAndUpdate(end_line, end_col, num_of_chars_to_delete);

        try self.string_buffer.replaceRange(new_end_byte, num_of_bytes_to_delete, &[0]u8{});

        self.cursor.set(end_line, end_col);

        /////////////////////////////

        try self.updateTree(new_end_byte, new_end_byte, start_byte, new_end_point, new_end_point, start_point);

        try self.updateCells();
    }

    pub fn insertChars(self: *@This(), chars: []const u8) !void {
        const start_line = self.cursor.line;
        const start_col = self.cursor.col;
        const start_point = ts.Point{ .row = @intCast(start_line), .column = @intCast(start_col) };
        const start_byte = try self.buffer.getByteOffsetAtPoint(start_line, start_col);

        const end_line, const end_col = try self.buffer.insertCharsAndUpdate(start_line, start_col, chars);
        const new_end_point = ts.Point{ .row = @intCast(end_line), .column = @intCast(end_col) };
        const new_end_byte = start_byte + chars.len;

        /////////////////////////////

        try self.string_buffer.insertSlice(start_byte, chars);
        self.cursor.set(end_line, end_col);
        try self.updateTree(start_byte, start_byte, new_end_byte, start_point, start_point, new_end_point);
        try self.updateCells();
    }

    fn updateTree(self: *@This(), start_byte: usize, old_end_byte: usize, new_end_byte: usize, start_point: ts.Point, old_end_point: ts.Point, new_end_point: ts.Point) !void {
        if (self.tree) |_| {
            const edit = ts.InputEdit{
                .start_byte = @intCast(start_byte),
                .old_end_byte = @intCast(old_end_byte),
                .new_end_byte = @intCast(new_end_byte),
                .start_point = start_point,
                .old_end_point = old_end_point,
                .new_end_point = new_end_point,
            };
            self.tree.?.edit(&edit);

            const old_tree = self.tree;
            defer old_tree.?.destroy();
            self.tree = try self.parser.?.parseString(old_tree, self.string_buffer.items);
        }
    }

    fn updateCells(self: *@This()) !void {
        const old_cells = self.cells;
        defer old_cells.deinit();
        const old_lines = self.lines;
        defer old_lines.deinit();
        self.cells, self.lines = try getUpdatedCells(self, self.highlight_query, self.highlight_filter);
    }
};

const test_patterns =
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
    window: *const WindowBackend,
    query: *ts.Query,
    filter: *PredicatesFilter,
    comparisons: []const []const []const u8,
) !void {
    const source = window.string_buffer.items;
    const cursor = try ts.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(query, window.tree.?.getRootNode());

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

test "Window.deleteChars()" {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    var window = try WindowBackend.createWithTreeSitter(a, ziglang, test_patterns);
    defer window.deinit();

    const query = try ts.Query.create(ziglang, test_patterns);
    defer query.destroy();
    var filter = try PredicatesFilter.init(a, query);
    defer filter.deinit();

    /////////////////////////////

    {
        try eqStr("", window.string_buffer.items);

        try window.insertChars("c");
        try eqStr("c", window.string_buffer.items);

        try window.deleteCharsBackwards(1);
        try eqStr("", window.string_buffer.items);

        try window.deleteCharsBackwards(1);
        try eqStr("", window.string_buffer.items);

        try window.deleteCharsBackwards(100);
        try eqStr("", window.string_buffer.items);
    }

    {
        try window.insertChars("const std = @import(\"std\");");
        try eqStr("const std = @import(\"std\");", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
        });

        try window.deleteCharsBackwards(8);
        try eqStr("const std = @import", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
        });

        try window.deleteCharsBackwards(10);
        try eqStr("const std", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
        });

        window.cursor.left(3);
        try window.insertChars("my");
        try eqStr("const mystd", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
        });

        try window.deleteCharsBackwards(1000);
        try eqStr("std", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"std"},
        });

        window.cursor.right(3, try window.buffer.num_of_chars_in_line(0));
        try window.deleteCharsBackwards(3);
        try eqStr("", window.string_buffer.items);
        try eq(Cursor{ .line = 0, .col = 0 }, window.cursor);
    }

    {
        try window.insertChars("const std = @import(\"std\");");
        try eqStr("const std = @import(\"std\");", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
        });

        try window.insertChars("\nconst a = 10;");
        try eqStr("const std = @import(\"std\");\nconst a = 10;", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
            &[_][]const u8{"const"},
        });

        try window.deleteCharsBackwards(8);
        try eqStr("const std = @import(\"std\");\nconst", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
            &[_][]const u8{"const"},
        });
        try eq(Cursor{ .line = 1, .col = 5 }, window.cursor);

        try window.deleteCharsBackwards(6);
        try eqStr("const std = @import(\"std\");", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
        });

        try window.insertChars("\nconst");
        try eqStr("const std = @import(\"std\");\nconst", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
            &[_][]const u8{"@import"},
            &[_][]const u8{"const"},
        });
        try eq(Cursor{ .line = 1, .col = 5 }, window.cursor);

        try window.deleteCharsBackwards(24);
        try eqStr("const std", window.string_buffer.items);
        try testWindowTreeHasMatches(window, query, filter, &[_][]const []const u8{
            &[_][]const u8{"const"},
            &[_][]const u8{"std"},
        });
    }
}

test "Window.insertChars()" {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    var window = try WindowBackend.createWithTreeSitter(a, ziglang, test_patterns);
    defer window.deinit();

    const query = try ts.Query.create(ziglang, test_patterns);
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

//////////////////////////////////////////////////////////////////////////////////////////////

const HighlightMap = std.StringHashMap(rl.Color);

pub const zig_highlight_scm = @embedFile("submodules/tree-sitter-zig/queries/highlights.scm");

fn createExperimentalHighlightMap(a: Allocator) !HighlightMap {
    var map = HighlightMap.init(a);

    try map.put("comment", Color.gray);

    try map.put("keyword", Color.purple);
    try map.put("type.qualifier", Color.purple);

    try map.put("include", Color.red);

    try map.put("string", Color.yellow);
    try map.put("character", Color.yellow);

    try map.put("punctuation.bracket", Color.white);
    try map.put("punctuation.delimiter", Color.white);

    return map;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Cell = struct { char: []const u8, color: Color };
const Line = struct {
    start: usize,
    end: usize,

    fn cells(self: *@This(), win: *WindowBackend) []Cell {
        return win.cells.items[self.start..self.end];
    }
};

fn getUpdatedCells(win: *WindowBackend, query: ?*ts.Query, filter: ?*PredicatesFilter) !struct { std.ArrayList(Cell), std.ArrayList(Line) } {
    var cells = std.ArrayList(Cell).init(win.a);
    var lines = std.ArrayList(Line).init(win.a);

    var indexes = std.ArrayList(usize).init(win.a);
    defer indexes.deinit();

    const source = win.string_buffer.items;
    var iter = _b.code_point.Iterator{ .bytes = source };

    {
        var i: usize = 0;
        var j: usize = 0;
        var start_index: usize = 0;
        while (iter.next()) |cp| {
            try cells.append(Cell{ .char = source[i .. i + cp.len], .color = Color.ray_white });
            for (0..cp.len) |_| try indexes.append(j);
            if (cp.code == '\n') {
                try lines.append(Line{ .start = start_index, .end = j });
                start_index = cells.items.len;
            }
            i += cp.len;
            j += 1;
        }
        try lines.append(Line{ .start = start_index, .end = cells.items.len });
    }

    if (win.tree) |_| {
        const cursor = try ts.Query.Cursor.create();
        cursor.execute(query.?, win.tree.?.getRootNode());

        while (filter.?.nextMatch(source, cursor)) |pattern| {
            const cap = pattern.captures()[0];
            const capture_name = query.?.getCaptureNameForId(cap.id);
            if (win.highlight_map.?.get(capture_name)) |color| {
                for (cap.node.getStartByte()..cap.node.getEndByte()) |k| {
                    const cell_index = indexes.items[k];
                    if (cell_index < cells.items.len) cells.items[cell_index].color = color;
                }
            }
        }
    }

    return .{ cells, lines };
}

fn testCells(cells: []Cell, start: usize, end: usize, content: []const u8, color: Color) !void {
    var iter = _b.code_point.Iterator{ .bytes = content };
    for (start..end) |i| {
        const cp = iter.next().?;
        try eqStr(content[cp.offset .. cp.offset + cp.len], cells[i].char);
        try eq(cells[i].color, color);
    }
}

test getUpdatedCells {
    const a = std.testing.allocator;
    const ziglang = try ts.Language.get("zig");

    /////////////////////////////

    {
        var window = try WindowBackend.createWithTreeSitter(a, ziglang, zig_highlight_scm);
        defer window.deinit();
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(0, result.items.len);
        }
        try window.insertChars("c");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(1, result.items.len);
            try testCells(result.items, 0, 1, "c", Color.ray_white);
        }
        try window.insertChars("onst");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(5, result.items.len);
            try testCells(result.items, 0, 5, "const", Color.purple);
        }
    }

    {
        var window = try WindowBackend.createWithTreeSitter(a, ziglang, zig_highlight_scm);
        defer window.deinit();
        try window.insertChars("👋");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(1, result.items.len);
            try testCells(result.items, 0, 1, "👋", Color.ray_white);
        }
        try window.insertChars(" const");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(7, result.items.len);
            try testCells(result.items, 0, 2, "👋 ", Color.ray_white);
            try testCells(result.items, 2, 7, "const", Color.purple);
        }
    }

    {
        var window = try WindowBackend.createWithTreeSitter(a, ziglang, zig_highlight_scm);
        defer window.deinit();
        try window.insertChars("const std = @import(\"std\")");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try testCells(result.items, 0, 5, "const", Color.purple);
            try testCells(result.items, 5, 12, " std = ", Color.ray_white);
            try testCells(result.items, 12, 19, "@import", Color.red);
            try testCells(result.items, 19, 20, "(", Color.white);
            try testCells(result.items, 20, 25, "\"std\"", Color.yellow);
            try testCells(result.items, 25, 26, ")", Color.white);
        }
    }

    {
        var window = try WindowBackend.createWithTreeSitter(a, ziglang, zig_highlight_scm);
        defer window.deinit();
        try window.insertChars("const emoji = \"👋\";");
        {
            const result, _ = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try testCells(result.items, 0, 5, "const", Color.purple);
            try testCells(result.items, 5, 14, " emoji = ", Color.ray_white);
            try testCells(result.items, 14, 17, "\"👋\"", Color.yellow);
            try testCells(result.items, 17, 18, ";", Color.white);
        }
    }

    /////////////////////////////

    {
        var window = try WindowBackend.createWithTreeSitter(a, ziglang, zig_highlight_scm);
        defer window.deinit();
        try window.insertChars("hello\nman\nover\nthere\nvery nice 👋");
        {
            _, const lines = try getUpdatedCells(window, window.highlight_query, window.highlight_filter);
            try eq(5, lines.items.len);
            try testCells(window.cells.items[lines.items[0].start..lines.items[0].end], 0, 5, "hello", Color.ray_white);
            try testCells(window.cells.items[lines.items[1].start..lines.items[1].end], 0, 3, "man", Color.ray_white);
            try testCells(window.cells.items[lines.items[2].start..lines.items[2].end], 0, 4, "over", Color.ray_white);
            try testCells(window.cells.items[lines.items[3].start..lines.items[3].end], 0, 5, "there", Color.ray_white);
            try testCells(window.cells.items[lines.items[4].start..lines.items[4].end], 0, 11, "very nice 👋", Color.ray_white);
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const chars_to_stop_at = [_][]const u8{
    " ", ";", ":", "'", "\"", "!", "@", "#", "$", "%", "^",
    "&", "*", "(", ")", "-",  "+", "=", "{", "}", "[", "]",
    "|", "<", ">", ",", ".",  "?", "/", "~", "`",
};

const CharsToStopAtMap = std.StringHashMap(bool);
fn createCharsToStopAtHashMap(a: Allocator) !CharsToStopAtMap {
    var map = CharsToStopAtMap.init(a);
    for (chars_to_stop_at) |char| try map.put(char, true);
    return map;
}

fn moveCursorBackwardsByWord(win: *WindowBackend, map: *CharsToStopAtMap, count: usize) void {
    for (0..count) |_| {
        var cells = win.lines.items[win.cursor.line].cells(win);

        if (win.cursor.col == 0) {
            if (win.cursor.line == 0) continue;
            const new_cursor_line = win.cursor.line - 1;
            cells = win.lines.items[new_cursor_line].cells(win);
            win.cursor.set(new_cursor_line, cells.len);
        }

        {
            var i: usize = win.cursor.col - 1;
            while (i > 0) {
                if (map.get(cells[i].char) == null) {
                    i += 1;
                    break;
                }
                i -|= 1;
            }
            win.cursor.set(win.cursor.line, i);
        }

        {
            var i: usize = win.cursor.col - 1;
            while (i > 0) {
                if (map.get(cells[i].char)) |_| {
                    i += 1;
                    break;
                }
                i -|= 1;
            }
            win.cursor.set(win.cursor.line, i);
        }
    }
}

test "[count] words backward" {
    const a = std.testing.allocator;
    var chars_to_stop_at_map = try createCharsToStopAtHashMap(a);
    defer chars_to_stop_at_map.deinit();

    {
        var win = try WindowBackend.create(a);
        defer win.deinit();
        try win.insertChars("const");
        try eqStr("const", win.string_buffer.items);

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 1);
        try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);

        try win.insertChars("okay ");
        try eqStr("okay const", win.string_buffer.items);
    }

    {
        var win = try WindowBackend.create(a);
        defer win.deinit();
        try win.insertChars("const std");
        try eqStr("const std", win.string_buffer.items);

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 1);
        try eq(Cursor{ .line = 0, .col = 6 }, win.cursor);
        try win.insertChars("okay ");
        try eqStr("const okay std", win.string_buffer.items);

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 2);
        try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
        try win.insertChars("// ");
        try eqStr("// const okay std", win.string_buffer.items);
    }

    {
        var win = try WindowBackend.create(a);
        defer win.deinit();
        try win.insertChars("const  std");

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 1);
        try eq(Cursor{ .line = 0, .col = 7 }, win.cursor);
        try win.insertChars("super ");
        try eqStr("const  super std", win.string_buffer.items);

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 2);
        try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
        try win.insertChars("//");
        try eqStr("//const  super std", win.string_buffer.items);
    }

    {
        var win = try WindowBackend.create(a);
        defer win.deinit();
        try win.insertChars("hello\nworld");

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 1);
        try eq(Cursor{ .line = 1, .col = 0 }, win.cursor);
        try win.insertChars("my ");
        try eqStr("hello\nmy world", win.string_buffer.items);

        moveCursorBackwardsByWord(win, &chars_to_stop_at_map, 2);
        try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
        try win.insertChars("say ");
        try eqStr("say hello\nmy world", win.string_buffer.items);
    }
}
