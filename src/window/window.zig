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

content_restrictions: ContentRestrictions = .none,
default_display: CachedContents.Display,

cached: CachedContents = undefined,
cache_strategy: CachedContents.CacheStrategy = .entire_buffer,

queries: std.StringArrayHashMap(*sitter.StoredQuery),

font_manager: *anyopaque = undefined,
font_callback: GetGlyphSizeCallback = undefined,
image_manager: *anyopaque = undefined,
image_callback: GetImageInfoCallback = undefined,

pub fn create(
    a: Allocator,
    buf: *Buffer,
    default_display: CachedContents.Display,
) !*Window {
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

pub fn destroy(self: *@This()) void {
    self.queries.deinit();
    self.a.destroy(self);
}

pub fn initCache(self: *@This(), cache_strategy: CachedContents.CacheStrategy) !void {
    self.cached = try CachedContents.init(self, cache_strategy);
}

pub fn registerImageManager(self: *@This(), ctx: *anyopaque, cb: GetImageInfoCallback) !void {
    self.image_manager = ctx;
    self.image_callback = cb;
}

pub fn registerFontManager(self: *@This(), ctx: *anyopaque, cb: GetGlyphSizeCallback) !void {
    self.font_manager = ctx;
    self.font_callback = cb;
}

///////////////////////////// Insert

pub fn insertChars(self: *@This(), cursor: *Cursor, chars: []const u8) !void {
    const new_pos, const may_ts_ranges = try self.buf.insertChars(chars, cursor.line, cursor.col);

    const change_start = cursor.line;
    const change_end = new_pos.line;
    assert(change_start <= change_end);

    const len_diff = try self.cached.updateObsoleteLines(change_start, change_start, change_start, change_end);
    self.cached.updateEndLine(len_diff);

    try self.cached.updateObsoleteDisplays(change_start, change_start, change_start, change_end);
    assert(self.cached.lines.items.len == self.cached.displays.items.len);

    try self.cached.updateObsoleteTreeSitterToDisplays(change_start, change_end, may_ts_ranges);

    cursor.* = .{ .line = new_pos.line, .col = new_pos.col };
}

test insertChars {
    {
        var tswin = try TSWin.init("", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        try eqStrU21Slice(&.{""}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "h");
        try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "ello");
        try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "\n");
        try eqStrU21Slice(&.{ "hello", "" }, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "\nworld");
        try eqStrU21Slice(&.{ "hello", "", "world" }, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        {
            try tswin.win.insertChars(&tswin.win.cursor, "v");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "v", .default);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "ar");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, " not_false = true;");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try eqStrU21Slice(&.{"var not_false = true;"}, tswin.win.cached.lines.items);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "\n");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try eqStrU21Slice(&.{ "var not_false = true;", "" }, tswin.win.cached.lines.items);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "const eleven = 11;");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " eleven = ", .default);
            try test_iter.next(1, "11", .{ .hl_group = "number" });
            try test_iter.next(1, ";", .default);
            try eqStrU21Slice(&.{ "var not_false = true;", "const eleven = 11;" }, tswin.win.cached.lines.items);
        }
    }
}

///////////////////////////// Delete

pub fn backspace(self: *@This(), cursor: *Cursor) !void {
    if (cursor.line == 0 and cursor.col == 0) return;

    var start_line: usize = cursor.line;
    var start_col: usize = cursor.col -| 1;
    const end_line: usize = cursor.line;
    const end_col: usize = cursor.col;

    if (self.cursor.col == 0 and self.cursor.line > 0) {
        start_line = self.cursor.line - 1;

        // FIXME: this will fail once we touch CacheStrategy.section
        assert(self.cursor.line - 1 >= self.cached.start_line);

        const line_index = self.cursor.line - 1 - self.cached.start_line;
        start_col = self.cached.lines.items[line_index].len;
    }

    try self.deleteRange(.{ start_line, start_col }, .{ end_line, end_col });

    cursor.set(start_line, start_col);
}

test backspace {
    {
        var tswin = try TSWin.init("const not_false = true;", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();

        tswin.win.cursor.set(0, tswin.win.cached.lines.items[0].len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
        try tswin.win.backspace(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.backspace(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = tru", .default);
        }
        try tswin.win.backspace(&tswin.win.cursor);
        try tswin.win.backspace(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = t", .default);
        }

        tswin.win.cursor.set(0, 1);
        try tswin.win.backspace(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "onst not_false = t", .default);
        }

        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace(&tswin.win.cursor);
        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace(&tswin.win.cursor);
        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace(&tswin.win.cursor);
    }

    {
        var tswin = try TSWin.init("const one = 1;\nvar two = 2;\nconst not_false = true;", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " two = ", .default);
            try test_iter.next(1, "2", .{ .hl_group = "number" });
            try test_iter.next(1, ";", .default);
            try test_iter.next(2, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(2, " not_false = ", .default);
            try test_iter.next(2, "true", .{ .hl_group = "boolean" });
            try test_iter.next(2, ";", .default);
        }
        tswin.win.cursor.set(1, 0);
        try tswin.win.backspace(&tswin.win.cursor);
        try eq(2, tswin.win.cached.lines.items.len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " two = ", .default);
            try test_iter.next(0, "2", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " not_false = ", .default);
            try test_iter.next(1, "true", .{ .hl_group = "boolean" });
            try test_iter.next(1, ";", .default);
        }
        tswin.win.cursor.set(1, 0);
        try tswin.win.backspace(&tswin.win.cursor);
        try eq(1, tswin.win.cached.lines.items.len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " two = ", .default);
            try test_iter.next(0, "2", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
        for (0..100) |_| try tswin.win.backspace(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
    }
}

const Range = struct { usize, usize };
fn sortRanges(a: Range, b: Range) struct { Range, Range } {
    if (a[0] == b[0]) {
        if (a[1] < b[1]) return .{ a, b };
        return .{ b, a };
    }
    if (a[0] < b[0]) return .{ a, b };
    return .{ b, a };
}

test sortRanges {
    {
        const start, const end = sortRanges(.{ 0, 0 }, .{ 0, 1 });
        try eq(.{ 0, 0 }, start);
        try eq(.{ 0, 1 }, end);
    }
    {
        const start, const end = sortRanges(.{ 0, 2 }, .{ 0, 10 });
        try eq(.{ 0, 2 }, start);
        try eq(.{ 0, 10 }, end);
    }
    {
        const start, const end = sortRanges(.{ 1, 0 }, .{ 0, 10 });
        try eq(.{ 0, 10 }, start);
        try eq(.{ 1, 0 }, end);
    }
}

fn deleteRange(self: *@This(), a: struct { usize, usize }, b: struct { usize, usize }) !void {
    const start_range, const end_range = sortRanges(a, b);

    const may_ts_ranges = try self.buf.deleteRange(start_range, end_range);

    const len_diff = try self.cached.updateObsoleteLines(start_range[0], end_range[0], start_range[0], start_range[0]);
    self.cached.updateEndLine(len_diff);

    try self.cached.updateObsoleteDisplays(start_range[0], end_range[0], start_range[0], start_range[0]);
    assert(self.cached.lines.items.len == self.cached.displays.items.len);

    try self.cached.updateObsoleteTreeSitterToDisplays(start_range[0], start_range[0], may_ts_ranges);
}

test deleteRange {
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 4 }, .{ 0, 5 });
        try eqStrU21Slice(&.{ "hell", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 1 });
        try eqStrU21Slice(&.{ "ell", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 1, 0 }, .{ 0, 3 });
        try eqStrU21Slice(&.{ "ellworld", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 2 }, .{ 1, 3 });
        try eqStrU21Slice(&.{"elus"}, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 3 }, .{ 1, 2 });
        try eqStrU21Slice(&.{ "helrld", "venus" }, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 3 }, .{ 2, 2 });
        try eqStrU21Slice(&.{"helnus"}, tswin.win.cached.lines.items);
    }

    {
        var tswin = try TSWin.init("xconst not_false = true", .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "xconst not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 1 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.deleteRange(.{ 0, 22 }, .{ 0, 21 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = tru", .default);
        }
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 2 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "nst not_false = tru", .default);
        }
    }
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
    const DisplaySize = struct { width: f32, height: f32 };
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
    sizes: ArrayList([]DisplaySize) = undefined,

    start_line: usize = 0,
    end_line: usize = 0,

    const InitError = error{ OutOfMemory, LineOutOfBounds };
    // TODO:                                             list specific errors
    fn init(win: *const Window, strategy: CacheStrategy) anyerror!@This() {
        var self = try CachedContents.init_bare_internal(win, strategy);

        self.lines = try createLines(self.arena.allocator(), win, self.start_line, self.end_line);
        assert(self.lines.items.len == self.end_line - self.start_line + 1);

        self.displays = try self.createDefaultDisplays(self.start_line, self.end_line);
        assert(self.lines.items.len == self.displays.items.len);

        try self.applyTreeSitterToDisplays(self.start_line, self.end_line);

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

    ///////////////////////////// Initial Creation

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

    // TODO:                                                                       list specific errors
    fn applyTreeSitterToDisplays(self: *@This(), start_line: usize, end_line: usize) anyerror!void {
        if (self.win.buf.tstree == null) return;

        for (self.win.queries.values()) |sq| {
            const query = sq.query;

            const cursor = try ts.Query.Cursor.create();
            defer cursor.destroy();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(start_line), .column = 0 },
                ts.Point{ .row = @intCast(end_line + 1), .column = 0 },
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

    test applyTreeSitterToDisplays {
        const source =
            \\const std = @import("std");
            \\const Allocator = std.mem.Allocator;
        ;
        var tswin = try TSWin.init(source, .entire_buffer, true, &.{"trimed_down_highlights"});
        defer tswin.deinit();

        {
            var cc = try CachedContents.init_bare_internal(tswin.win, .entire_buffer);
            defer cc.deinit();
            cc.lines = try createLines(cc.arena.allocator(), tswin.win, cc.start_line, cc.end_line);
            cc.displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);

            try cc.applyTreeSitterToDisplays(cc.start_line, cc.end_line);
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

        try tswin.win.enableQuery("std_60_inter");
        {
            var cc = try CachedContents.init(tswin.win, .entire_buffer);
            defer cc.deinit();
            var test_iter = DisplayChunkTester{ .cc = cc };

            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " ", .default);
            try test_iter.next(0, "std", .{ .literal = .{ "Inter", 60, tswin.hl.get("variable").? } });
            try test_iter.next(0, " = ", .default);
            try test_iter.next(0, "@import", .{ .hl_group = "include" });
            try test_iter.next(0, "(\"std\");", .default);

            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " ", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, " = ", .default);
            try test_iter.next(1, "std", .{ .literal = .{ "Inter", 60, tswin.hl.get("variable").? } });
            try test_iter.next(1, ".mem.", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, ";", .default);
        }
    }

    // fn createDisplaySizes(self: *CachedContents, start_line: usize, end_line: usize) !ArrayList([]DisplaySize) {
    //     assert(start_line >= self.start_line and end_line <= self.end_line);
    //     const a = self.arena.allocator();
    //     var list = ArrayList([]DisplaySize).init(a);
    //     for (start_line..end_line + 1) |linenr| {
    //         const displays_index = linenr - self.start_line;
    //         const displays = self.displays.items[displays_index];
    //         const sizes = try a.alloc(DisplaySize, displays.len);
    //         for (displays) |d| {
    //             switch (d) {
    //                 .char => |char| {
    //                     // TODO:
    //                 },
    //                 .image => |image| {
    //                     // TODO:
    //                 },
    //             }
    //         }
    //         try list.append(sizes);
    //     }
    //     return list;
    // }
    //
    // test createDisplaySizes {
    //     const source =
    //         \\const std = @import("std");
    //         \\const Allocator = std.mem.Allocator;
    //     ;
    //     var tswin = try TSWin.initNoCache(source, true, &.{ "trimed_down_highlights", "std_60_inter" });
    //     defer tswin.deinit();
    //
    //     var cc = try CachedContents.init_bare_internal(tswin.win, .entire_buffer);
    //     cc.lines = try createLines(cc.arena.allocator(), tswin.win, cc.start_line, cc.end_line);
    //     cc.displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);
    //     try cc.applyTreeSitterToDisplays(cc.start_line, cc.end_line);
    //     cc.sizes = try cc.createDisplaySizes(cc.start_line, cc.end_line);
    //
    //     var iter = DisplayChunkTester{ .cc = cc };
    //     try iter.sizes(0, "const ", .{ .width = 30, .height = 40 });
    // }

    ///////////////////////////// Update Obsolete

    const UpdateLinesError = error{ OutOfMemory, LineOutOfBounds };
    fn updateObsoleteLines(self: *@This(), old_start: usize, old_end: usize, new_start: usize, new_end: usize) UpdateLinesError!i128 {
        assert(new_start <= new_end);
        assert(new_start >= self.start_line);

        const old_len: i128 = @intCast(self.lines.items.len);
        var new_lines = try createLines(self.arena.allocator(), self.win, new_start, new_end);
        try self.lines.replaceRange(new_start, old_end - old_start + 1, try new_lines.toOwnedSlice());

        const len_diff: i128 = @as(i128, @intCast(self.lines.items.len)) - old_len;
        assert(self.end_line + len_diff >= self.start_line);
        return len_diff;
    }

    test updateObsoleteLines {
        {
            var tswin = try TSWin.init("", .entire_buffer, true, &.{"trimed_down_highlights"});
            defer tswin.deinit();
            try eqStrU21Slice(&.{""}, tswin.win.cached.lines.items);

            _ = try tswin.buf.insertChars("h", 0, 0);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("ello", 0, 1);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("\n", 0, 5);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                try eq(1, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{ "hello", "" }, tswin.win.cached.lines.items);
            }
        }
        {
            var tswin = try TSWin.init("", .entire_buffer, true, &.{"trimed_down_highlights"});
            defer tswin.deinit();
            _ = try tswin.buf.insertChars("h", 0, 0);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("ello", 0, 1);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("\n", 0, 4);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                try eq(1, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{ "hell", "o" }, tswin.win.cached.lines.items);
            }
        }
    }

    fn updateEndLine(self: *@This(), len_diff: i128) void {
        const new_end_line = @as(i128, @intCast(self.end_line)) + len_diff;
        assert(new_end_line >= 0);
        self.end_line = @intCast(new_end_line);
    }

    fn updateObsoleteDisplays(self: *@This(), old_start: usize, old_end: usize, new_start: usize, new_end: usize) !void {
        var new_displays = try self.createDefaultDisplays(new_start, new_end);
        try self.displays.replaceRange(new_start, old_end - old_start + 1, try new_displays.toOwnedSlice());
    }

    test updateObsoleteDisplays {
        {
            var tswin = try TSWin.init("", .entire_buffer, true, &.{"trimed_down_highlights"});
            defer tswin.deinit();
            {
                _ = try tswin.buf.insertChars("h", 0, 0);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 0);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "h", .default);
            }
            {
                _ = try tswin.buf.insertChars("ello", 0, 1);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 0);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "hello", .default);
            }
            {
                _ = try tswin.buf.insertChars("\n", 0, 4);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 1);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "hell", .default);
                try test_iter.next(1, "o", .default);
            }
        }
    }

    fn updateObsoleteTreeSitterToDisplays(self: *@This(), base_start: usize, base_end: usize, ranges: ?[]const ts.Range) !void {
        var new_hl_start = base_start;
        var new_hl_end = base_end;
        if (ranges) |ts_ranges| {
            for (ts_ranges) |r| {
                new_hl_start = @min(new_hl_start, r.start_point.row);
                new_hl_end = @max(new_hl_end, r.end_point.row);
            }
        }
        try self.applyTreeSitterToDisplays(new_hl_start, new_hl_end);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Types

const StoredQuery = struct {
    query: ts.Query,
    pattern: []const u8,
    id: []const u8,
};

const ContentRestrictions = union(enum) {
    none,
    section: struct { start_line: usize, end_line: usize },
    query: struct { id: []const u8 },
};

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    fn set(self: *@This(), line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }
};

pub const ImageInfo = struct {
    width: f32,
    height: f32,
};
pub const GetImageInfoCallback = *const fn (ctx: *anyopaque, path: []const u8) ?ImageInfo;

pub const Glyph = struct {
    advanceX: i32,
    offsetX: i32,
    width: f32,
    height: f32,
};
pub const GlyphMap = std.AutoArrayHashMap(u21, Glyph);
pub const GetGlyphSizeCallback = *const fn (ctx: *anyopaque, name: []const u8, size: i32, char: u21) ?Glyph;

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
        literal: struct { []const u8, i32, u32 },
    };

    fn sizes(self: *@This(), linenr: usize, expected_str: []const u8, expected: CachedContents.DisplaySize) !void {
        defer self.i += expected_str.len;
        try self.linesCheck(linenr, expected_str);

        const s = self.cc.sizes.items[linenr];
        for (s[self.i .. self.i + expected_str.len]) |size| {
            errdefer std.debug.print("expected width {d} | {d}\n", .{ expected.width, size.width });
            errdefer std.debug.print("expected height {d} | {d}\n", .{ expected.height, size.height });
            try eq(expected, size);
        }
    }

    fn linesCheck(self: *@This(), linenr: usize, expected_str: []const u8) !void {
        if (linenr != self.current_line) {
            self.current_line = linenr;
            self.i = 0;
        }

        try eqStrU21(expected_str, self.cc.lines.items[linenr][self.i .. self.i + expected_str.len]);
    }

    fn next(self: *@This(), linenr: usize, expected_str: []const u8, expected_variant: ChunkVariant) !void {
        defer self.i += expected_str.len;
        try self.linesCheck(linenr, expected_str);

        var expected_display = self.cc.win.default_display;
        if (expected_display == .char) {
            switch (expected_variant) {
                .hl_group => |hl_group| {
                    const color = self.cc.win.buf.langsuite.?.highlight_map.?.get(hl_group).?;
                    expected_display.char.color = color;
                },
                .literal => |literal| {
                    expected_display.char.font_face = literal[0];
                    expected_display.char.font_size = literal[1];
                    expected_display.char.color = literal[2];
                },
                else => {},
            }
        }

        const displays = self.cc.displays.items[linenr];
        for (displays[self.i .. self.i + expected_str.len], 0..) |d, i| {
            errdefer std.debug.print("display comparison failed at index [{d}] of sequence '{s}'\n", .{ i, expected_str });
            try eqDisplay(expected_display, d);
        }
    }
};

fn eqDisplay(expected: CachedContents.Display, got: CachedContents.Display) !void {
    switch (got) {
        .char => |char| {
            errdefer std.debug.print("expected color 0x{x} got 0x{x}\n", .{ expected.char.color, char.color });
            try eqStr(expected.char.font_face, char.font_face);
            try eq(expected.char.font_size, char.font_size);
            try eq(expected.char.color, char.color);
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

const MockManager = struct {
    a: Allocator,
    arena: std.heap.ArenaAllocator,
    maps: std.StringHashMap(GlyphMap),

    fn getGlyphMap(ctx: *anyopaque, name: []const u8, size: i32, char: u21) ?Glyph {
        _ = size;
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        if (self.maps.get(name)) |map| if (map.get(char)) |glyph| return glyph;
        return null;
    }

    // TODO: generate dynamic sizes using RNG with seed

    fn generateMonoGlyphMap(self: *@This(), size: i32, width_aspect_ratio: f32) GlyphMap {
        const height: f32 = @floatFromInt(size);
        const width: f32 = height * width_aspect_ratio;
        const glyph = Glyph{
            .width = width,
            .height = height,
            .advanceX = 15,
            .offsetX = 4,
        };
        var map = GlyphMap.init(self.arena.allocator());
        for (32..127) |i| map.put(@intCast(i), glyph) catch unreachable;
        return map;
    }

    fn getImageInfo(_: *anyopaque, path: []const u8) ?ImageInfo {
        if (eql(u8, path, "kekw.png")) return ImageInfo{ .width = 420, .height = 420 };
        return null;
    }

    fn create(a: Allocator) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .maps = std.StringHashMap(GlyphMap).init(self.arena.allocator()),
        };
        try self.maps.put("Meslo", self.generateMonoGlyphMap(40, 0.75));
        try self.maps.put("Inter", self.generateMonoGlyphMap(40, 0.5));
        return self;
    }

    fn destroy(self: *@This()) void {
        self.arena.deinit();
        self.a.destroy(self);
    }
};

const TSWin = struct {
    langsuite: sitter.LangSuite = undefined,
    buf: *Buffer = undefined,
    win: *Window = undefined,
    hl: std.StringHashMap(u32) = undefined,
    mock_manager: *MockManager = undefined,

    fn init(
        source: []const u8,
        cache_strategy: CachedContents.CacheStrategy,
        disable_default_queries: bool,
        enabled_queries: []const []const u8,
    ) !@This() {
        var self = try initNoCache(source, disable_default_queries, enabled_queries);
        try self.win.initCache(cache_strategy);
        return self;
    }

    fn initMockCallbacks(self: *@This()) !void {
        self.mock_manager = try MockManager.create(testing_allocator);
        try self.win.registerFontManager(self.mock_manager, MockManager.getGlyphMap);
        try self.win.registerImageManager(self.mock_manager, MockManager.getImageInfo);
    }

    fn initNoCache(
        source: []const u8,
        disable_default_queries: bool,
        enabled_queries: []const []const u8,
    ) !@This() {
        var self = TSWin{
            .langsuite = try sitter.LangSuite.create(.zig),
            .buf = try Buffer.create(idc_if_it_leaks, .string, source),
        };
        try self.langsuite.initializeQueryMap();
        try self.langsuite.initializeNightflyColorscheme(testing_allocator);
        self.hl = self.langsuite.highlight_map.?;
        try self.addCustomQueries();

        try self.buf.initiateTreeSitter(self.langsuite);

        self.win = try Window.create(testing_allocator, self.buf, _default_display);
        if (disable_default_queries) self.win.disableDefaultQueries();
        for (enabled_queries) |query_id| try self.win.enableQuery(query_id);

        try self.initMockCallbacks();

        return self;
    }

    fn addCustomQueries(self: *@This()) !void {
        try self.langsuite.addQuery("std_60_inter",
            \\ (
            \\   (IDENTIFIER) @variable
            \\   (#eq? @variable "std")
            \\   (#size! 60)
            \\   (#font! "Inter")
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
            \\ (INTEGER) @number
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
        self.mock_manager.destroy();
    }
};
