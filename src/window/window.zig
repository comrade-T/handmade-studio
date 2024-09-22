const Window = @This();
const std = @import("std");

const Buffer = @import("neo_buffer").Buffer;
const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const idc_if_it_leaks = std.heap.page_allocator;
const testing_allocator = std.testing.allocator;
const assert = std.debug.assert;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Window

a: Allocator,
buf: *Buffer,

cursor: Cursor = .{},

content_restrictions: ContentRestrictions = .none, // TODO: add .query variant in the future.
cached: CachedContents = undefined,
default_display: CachedContents.Display,

queries: std.StringArrayHashMap(*sitter.StoredQuery),

pub fn create(a: Allocator, buf: *Buffer, default_display: CachedContents.Display) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .buf = buf,
        .default_display = default_display,
        .queries = std.StringArrayHashMap(*sitter.StoredQuery).init(a),
    };
    if (buf.tstree) |_| try self.enableQuery(sitter.DEFAULT_QUERY_ID);
    return self;
}

test create {
    var buf = try Buffer.create(testing_allocator, .string, "");
    defer buf.destroy();
    var win = try Window.create(testing_allocator, buf, _default_display);
    defer win.destroy();
    try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
}

pub fn destroy(self: *@This()) void {
    self.queries.deinit();
    self.a.destroy(self);
}

pub fn disableDefaultQueries(self: *@This()) void {
    try self.disableQuery(sitter.DEFAULT_QUERY_ID);
}

pub fn disableQuery(self: *@This(), name: []const u8) !void {
    _ = self.queries.orderedRemove(name);
}

pub fn enableQuery(self: *@This(), name: []const u8) !void {
    assert(self.buf.langsuite.?.queries != null);
    const langsuite = self.buf.langsuite orelse return;
    const queries = langsuite.queries orelse return;
    const ptr = queries.get(name) orelse return;
    _ = try self.queries.getOrPutValue(name, ptr);
}

fn bols(self: *const @This()) u32 {
    return self.buf.roperoot.weights().bols;
}

fn endLineNr(self: *const @This()) u32 {
    return self.bols() -| 1;
}

////////////////////////////////////////////////////////////////////////////////////////////// Supporting Structs

const CachedContents = struct {
    const Display = union(enum) {
        const Char = struct { font_size: i32, font_face: []const u8, color: u32 };
        const Image = struct { path: []const u8 };
        char: Char,
        image: Image,
    };
    const CacheStrategy = union(enum) {
        const Section = struct { start_line: usize, end_line: usize };
        entire_buffer,
        section: Section,
    };

    arena: ArenaAllocator,
    win: *const Window,

    lines: ArrayList([]u21) = undefined,
    displays: ArrayList([]Display) = undefined,

    start_line: usize = 0,
    end_line: usize = 0,

    const InitError = error{OutOfMemory};
    fn init(win: *const Window, strategy: CacheStrategy) InitError!@This() {
        var self = try CachedContents.init_bare_internal(win, strategy);

        self.lines = try createLines(self.arena.allocator(), win, self.start_line, self.end_line);
        assert(self.lines.items.len == self.end_line - self.start_line + 1);

        self.displays = try createDefaultDisplays(self.arena.allocator(), win, self.start_line, self.end_line);
        assert(self.lines.values().len == self.displays.values().len);

        try self.applyTreeSitterDisplays();

        return self;
    }

    const InitBareInternalError = error{OutOfMemory};
    fn init_bare_internal(win: *const Window, strategy: CacheStrategy) InitBareInternalError!@This() {
        var self = CachedContents{
            .arena = ArenaAllocator.init(std.heap.page_allocator),
            .win = win,
        };
        const end_linenr = self.win.endLineNr();
        switch (strategy) {
            .entire_buffer => self.end_line = end_linenr,
            .section => |section| {
                assert(section.start_line <= section.end_line);
                assert(section.start_line <= end_linenr and section.end_line <= end_linenr);
                self.start_line = section.start_line;
                self.end_line = section.end_line;
            },
        }
        return self;
    }

    test init_bare_internal {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        {
            const cc = try CachedContents.init_bare_internal(win, .entire_buffer);
            try eq(0, cc.start_line);
            try eq(4, cc.end_line);
        }
        {
            const cc = try CachedContents.init_bare_internal(win, .{ .section = .{ .start_line = 0, .end_line = 2 } });
            try eq(0, cc.start_line);
            try eq(2, cc.end_line);
        }
        {
            const cc = try CachedContents.init_bare_internal(win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            try eq(2, cc.start_line);
            try eq(4, cc.end_line);
        }
    }

    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    const CreateLinesError = error{ OutOfMemory, LineOutOfBounds };
    fn createLines(a: Allocator, win: *const Window, start_line: usize, end_line: usize) CreateLinesError!ArrayList([]u21) {
        assert(start_line <= end_line);
        assert(start_line <= win.endLineNr() and end_line <= win.endLineNr());
        var lines = ArrayList([]u21).init(a);
        for (start_line..end_line + 1) |linenr| {
            const line = try win.buf.roperoot.getLineEx(a, linenr);
            try lines.append(line);
        }
        return lines;
    }

    test createLines {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        {
            var cc = try CachedContents.init_bare_internal(win, .entire_buffer);
            const lines = try createLines(cc.arena.allocator(), win, cc.start_line, cc.end_line);
            try eqStrU21Slice(&.{ "1", "22", "333", "4444", "55555" }, lines.items);
        }
        {
            var cc = try CachedContents.init_bare_internal(win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            const lines = try createLines(cc.arena.allocator(), win, cc.start_line, cc.end_line);
            try eqStrU21Slice(&.{ "333", "4444", "55555" }, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 0);
            try eqStrU21Slice(&.{"1"}, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 1);
            try eqStrU21Slice(&.{ "1", "22" }, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 1, 2);
            try eqStrU21Slice(&.{ "22", "333" }, lines.items);
        }
    }

    const CreateDefaultDisplaysError = error{OutOfMemory};
    fn createDefaultDisplays(self: *CachedContents, start_line: usize, end_line: usize) CreateDefaultDisplaysError!ArrayList([]Display) {
        assert(start_line >= self.start_line and end_line <= self.end_line);
        const a = self.arena.allocator();
        var list = ArrayList([]Display).init(a);
        for (start_line..end_line + 1) |linenr| {
            const line_index = linenr - self.start_line;
            const line = self.lines.items[line_index];
            const displays = try a.alloc(Display, line.len);
            @memset(displays, self.win.default_display);
            try list.append(displays);
        }
        return list;
    }

    test createDefaultDisplays {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        const dd = _default_display;

        // CachedContents contains lines & displays for entire buffer
        {
            var cc = try CachedContents.init_bare_internal(win, .entire_buffer);
            cc.lines = try createLines(cc.arena.allocator(), win, cc.start_line, cc.end_line);
            {
                const displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);
                try eq(5, displays.items.len);
                try eqDisplays(&.{dd}, displays.items[0]);
                try eqDisplays(&.{ dd, dd }, displays.items[1]);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[2]);
                try eqDisplays(&.{ dd, dd, dd, dd }, displays.items[3]);
                try eqDisplays(&.{ dd, dd, dd, dd, dd }, displays.items[4]);
            }
            {
                const displays = try cc.createDefaultDisplays(0, 0);
                try eq(1, displays.items.len);
                try eqDisplays(&.{dd}, displays.items[0]);
            }
            {
                const displays = try cc.createDefaultDisplays(1, 2);
                try eq(2, displays.items.len);
                try eqDisplays(&.{ dd, dd }, displays.items[0]);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[1]);
            }
        }

        // CachedContents contains lines & displays only for specific region
        {
            var cc = try CachedContents.init_bare_internal(win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            cc.lines = try createLines(cc.arena.allocator(), win, cc.start_line, cc.end_line);
            {
                const displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);
                try eq(3, displays.items.len);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[0]);
                try eqDisplays(&.{ dd, dd, dd, dd }, displays.items[1]);
                try eqDisplays(&.{ dd, dd, dd, dd, dd }, displays.items[2]);
            }
        }
    }

    // TODO:                                   list specific errors
    fn applyTreeSitterDisplays(self: *@This()) anyerror!void {
        if (self.win.buf.tstree == null) return;

        for (self.win.queries.values()) |sq| {
            const query = sq.query;

            const cursor = try ts.Query.Cursor.create();
            defer cursor.destroy();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(self.start_line), .column = 0 },
                ts.Point{ .row = @intCast(self.end_line + 1), .column = 0 },
            );
            cursor.execute(query, self.win.buf.tstree.?.getRootNode());

            const filter = try sitter.PredicatesFilter.init(self.arena.allocator(), query);
            defer filter.deinit();

            while (true) {
                const result = switch (filter.nextMatchInLines(query, cursor, Buffer.contentCallback, self.win.buf, self.start_line, self.end_line)) {
                    .match => |result| result,
                    .stop => break,
                };

                var display = self.win.default_display;

                if (self.win.buf.langsuite.?.highlight_map) |hl_map| {
                    if (hl_map.get(result.cap_name)) |color| {
                        if (self.win.default_display == .char) display.char.color = color;
                    }
                }

                if (result.directives) |directives| {
                    for (directives) |d| {
                        switch (d) {
                            .font => |face| {
                                if (display == .char) display.char.font_face = face;
                            },
                            .size => |size| {
                                if (display == .char) display.char.font_size = size;
                            },
                            .img => |path| {
                                if (display == .image) {
                                    display.image.path = path;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                }

                const node_start = result.cap_node.getStartPoint();
                const node_end = result.cap_node.getEndPoint();
                for (node_start.row..node_end.row + 1) |linenr| {
                    const line_index = linenr - self.start_line;
                    const start_col = if (linenr == node_start.row) node_start.column else 0;
                    const end_col = if (linenr == node_end.row) node_end.column else self.lines.items[line_index].len;
                    @memset(self.displays.items[line_index][start_col..end_col], display);
                }
            }
        }
    }

    test applyTreeSitterDisplays {
        const source =
            \\const std = @import("std");
            \\const Allocator = std.mem.Allocator;
        ;

        {
            var tswin = try TSWin.init(source);
            defer tswin.deinit();

            tswin.win.disableDefaultQueries();
            try tswin.win.enableQuery("trimed_down_highlights");

            var cc = try CachedContents.init_bare_internal(tswin.win, .entire_buffer);
            cc.lines = try createLines(cc.arena.allocator(), tswin.win, cc.start_line, cc.end_line);
            cc.displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);

            try cc.applyTreeSitterDisplays();
            var test_iter = DisplayChunkTester{ .cc = cc };

            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " std = ", .default);
            try test_iter.next(0, "@import", .{ .hl_group = "include" });
            try test_iter.next(0, "(\"std\");", .default);

            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " ", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, " = std.mem.", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, ";", .default);
        }
    }
};

const StoredQuery = struct {
    query: ts.Query,
    pattern: []const u8,
    id: []const u8,
};

const ContentRestrictions = union(enum) {
    none,
    restricted: struct { start_line: usize, end_line: usize },
};

const Cursor = struct { line: usize = 0, col: usize = 0 };

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

fn eqStrU21Slice(expected: []const []const u8, got: [][]u21) !void {
    try eq(expected.len, got.len);
    for (0..expected.len) |i| try eqStrU21(expected[i], got[i]);
}

fn eqStrU21(expected: []const u8, got: []u21) !void {
    var slice = try testing_allocator.alloc(u8, got.len);
    defer testing_allocator.free(slice);
    for (got, 0..) |cp, i| slice[i] = @intCast(cp);
    try eqStr(expected, slice);
}

const DisplayChunkTester = struct {
    i: usize = 0,
    current_line: usize = 0,
    cc: CachedContents,

    const ChunkVariant = union(enum) {
        default,
        hl_group: []const u8,
    };

    fn next(self: *@This(), linenr: usize, expected_str: []const u8, expected_variant: ChunkVariant) !void {
        if (linenr != self.current_line) {
            self.current_line = linenr;
            self.i = 0;
        }
        defer self.i += expected_str.len;

        try eqStrU21(expected_str, self.cc.lines.items[linenr][self.i .. self.i + expected_str.len]);

        var expected_display = self.cc.win.default_display;
        if (expected_display == .char) {
            switch (expected_variant) {
                .hl_group => |hl_group| {
                    const color = self.cc.win.buf.langsuite.?.highlight_map.?.get(hl_group).?;
                    expected_display.char.color = color;
                },
                else => {},
            }
        }

        const displays = self.cc.displays.items[linenr];
        for (displays[self.i .. self.i + expected_str.len]) |d| try eqDisplay(expected_display, d);
    }
};

fn eqDisplay(expected: CachedContents.Display, got: CachedContents.Display) !void {
    switch (got) {
        .char => |char| {
            try eq(char.color, expected.char.color);
            try eq(char.font_size, expected.char.font_size);
            try eqStr(char.font_face, expected.char.font_face);
        },
        .image => |image| {
            try eqStr(image.path, expected.image.path);
        },
    }
}

fn eqDisplays(expected: []const CachedContents.Display, got: []CachedContents.Display) !void {
    try eq(expected.len, got.len);
    for (0..expected.len) |i| try eqDisplay(expected[i], got[i]);
}

const _default_display = CachedContents.Display{
    .char = .{
        .font_size = 40,
        .font_face = "Meslo",
        .color = 0xF5F5F5F5,
    },
};

////////////////////////////////////////////////////////////////////////////////////////////// Test Setup Helpers

fn _createWinWithBuf(source: []const u8) !*Window {
    const buf = try Buffer.create(idc_if_it_leaks, .string, source);
    const win = try Window.create(idc_if_it_leaks, buf, _default_display);
    return win;
}

const TSWin = struct {
    langsuite: sitter.LangSuite = undefined,
    buf: *Buffer = undefined,
    win: *Window = undefined,

    fn init(source: []const u8) !@This() {
        var self = TSWin{
            .langsuite = try sitter.LangSuite.create(.zig),
            .buf = try Buffer.create(idc_if_it_leaks, .string, source),
        };
        try self.langsuite.initializeQueryMap();
        try self.langsuite.initializeNightflyColorscheme(testing_allocator);
        try self.addCustomQueries();

        try self.buf.initiateTreeSitter(self.langsuite);

        self.win = try Window.create(testing_allocator, self.buf, _default_display);

        return self;
    }

    fn addCustomQueries(self: *@This()) !void {
        try self.langsuite.addQuery("std_60_inter",
            \\ (
            \\   (IDENTIFIER) @variable
            \\   (#eq? @variable "std")
            \\   (#set! font-size 60)
            \\   (#set! font-name "Inter")
            \\ )
        );
        try self.langsuite.addQuery("trimed_down_highlights",
            \\ [
            \\   "const"
            \\   "var"
            \\ ] @type.qualifier
            \\
            \\ [
            \\  "true"
            \\  "false"
            \\ ] @boolean
            \\
            \\ ((BUILTINIDENTIFIER) @include
            \\ (#any-of? @include "@import" "@cImport"))
            \\
            \\ ;; assume TitleCase is a type
            \\ (
            \\   [
            \\     variable_type_function: (IDENTIFIER)
            \\     field_access: (IDENTIFIER)
            \\     parameter: (IDENTIFIER)
            \\   ] @type
            \\   (#match? @type "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
            \\ )
        );
    }

    fn deinit(self: *@This()) void {
        self.langsuite.destroy();
        self.buf.destroy();
        self.win.destroy();
    }
};
