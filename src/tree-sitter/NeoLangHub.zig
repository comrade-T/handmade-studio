// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const NeoLangHub = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const eq = std.testing.expectEqual;

const Buffer = @import("BufferOrchestrator").Buffer;

pub const ts = @import("bindings.zig");
pub const NeoStoredQuery = @import("NeoStoredQuery.zig");

pub const SupportedLanguage = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
langmap: std.AutoHashMapUnmanaged(*const ts.Language, NeoLangSuite) = .{},

trees: std.AutoHashMapUnmanaged(*const Buffer, std.ArrayListUnmanaged(*ts.Tree)) = .{},
captures: std.AutoHashMapUnmanaged(*const ts.Tree, CaptureMap) = .{},

pub fn init(a: Allocator) !NeoLangHub {
    return NeoLangHub{ .a = a };
}

pub fn deinit(self: *@This()) void {
    var tree_to_capture_map_iter = self.captures.valueIterator();
    while (tree_to_capture_map_iter.next()) |capture_map| self.freeCaptureMap(capture_map);
    self.captures.deinit(self.a);

    var treemap_iter = self.trees.valueIterator();
    while (treemap_iter.next()) |list| {
        defer list.deinit(self.a);
        for (list.items) |tree| tree.destroy();
    }
    self.trees.deinit(self.a);

    var langmap_iter = self.langmap.valueIterator();
    while (langmap_iter.next()) |ls| ls.deinit(self.a);
    self.langmap.deinit(self.a);
}

pub const LanguageID = union(enum) {
    language: *const ts.Language,
    lang_choice: SupportedLanguage,
};

pub fn getLangSuite(self: *@This(), lang_id: LanguageID) !*NeoLangSuite {
    const language = switch (lang_id) {
        .language => |lang| lang,
        .lang_choice => |lang_choice| switch (lang_choice) {
            .zig => try ts.Language.get("zig"),
        },
    };

    if (!self.langmap.contains(language))
        switch (lang_id) {
            .language => unreachable,
            .lang_choice => |lang_choice| {
                var langsuite = try NeoLangSuite.init(language);
                try langsuite.addDefaultHighlightQuery(self.a, lang_choice);
                try self.langmap.put(self.a, language, langsuite);
            },
        };

    return self.langmap.getPtr(language) orelse unreachable;
}

pub fn getLangChoiceFromFilePath(path: []const u8) ?SupportedLanguage {
    if (std.mem.endsWith(u8, path, ".zig")) return SupportedLanguage.zig;
    return null;
}

////////////////////////////////////////////////////////////////////////////////////////////// NeoLangSuite

const NeoLangSuite = struct {
    parser: *ts.Parser,
    queries: std.ArrayListUnmanaged(NeoStoredQuery) = .{},

    pub fn init(language: *const ts.Language) !NeoLangSuite {
        const parser = try ts.Parser.create();
        try parser.setLanguage(language);
        return NeoLangSuite{ .parser = parser };
    }

    pub fn deinit(self: *@This(), a: Allocator) void {
        for (self.queries.items) |*sq| sq.deinit();
        self.queries.deinit(a);
    }

    pub fn addDefaultHighlightQuery(self: *@This(), a: Allocator, lang_choice: SupportedLanguage) !void {
        const pattern_string = switch (lang_choice) {
            .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
        };
        try self.addQuery(a, pattern_string);
    }

    pub fn addQuery(self: *@This(), a: Allocator, pattern_string: []const u8) !void {
        const language = self.parser.getLanguage() orelse unreachable;
        const sq = try NeoStoredQuery.init(a, language, pattern_string);
        try self.queries.append(a, sq);
    }

    const ParseResult = struct {
        tree: *ts.Tree,
        changed_ranges: ?[]const ts.Range = null,

        fn freeChangedRanges(self: *const @This()) void {
            if (self.changed_ranges == null) return;
            std.c.free(@as(*anyopaque, @ptrCast(@constCast(self.changed_ranges.?.ptr))));
        }
    };

    fn parse(self: *@This(), buf: *const Buffer, may_old_tree: ?*ts.Tree, ranges: []const ts.Range) ?ParseResult {
        defer if (may_old_tree) |old_tree| old_tree.destroy();

        const parser = self.parser;
        defer parser.reset();
        parser.setIncludedRanges(ranges) catch return null;

        const PARSE_BUFFER_SIZE = 1024;
        const ParseCtx = struct {
            buf: *const Buffer,
            parse_buf: [PARSE_BUFFER_SIZE]u8 = undefined,
        };
        var parse_ctx = ParseCtx{ .buf = buf };

        const input: ts.Input = .{
            .payload = &parse_ctx,
            .read = struct {
                fn read(payload: ?*anyopaque, _: u32, ts_point: ts.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                    const ctx: *ParseCtx = @ptrCast(@alignCast(payload orelse return ""));
                    const result = ctx.buf.getRange(
                        .{ .line = @intCast(ts_point.row), .col = @intCast(ts_point.column) },
                        null,
                        &ctx.parse_buf,
                    );

                    bytes_read.* = @intCast(result.len);
                    return @ptrCast(result.ptr);
                }
            }.read,
            .encoding = .utf_8,
        };
        const new_tree = parser.parse(may_old_tree, input) catch return null;

        return ParseResult{
            .tree = new_tree,
            .changed_ranges = if (may_old_tree) |old_tree| old_tree.getChangedRanges(new_tree) else null,
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Parsing

pub fn parseMainTree(self: *@This(), buf: *const Buffer, lang_id: LanguageID) !bool {
    assert(!self.trees.contains(buf));
    var list = std.ArrayListUnmanaged(*ts.Tree){};
    const langsuite = try self.getLangSuite(lang_id);
    const parse_result = langsuite.parse(buf, null, &.{}) orelse return false;
    defer parse_result.freeChangedRanges();
    try list.append(self.a, parse_result.tree);
    try self.trees.put(self.a, buf, list);
    return true;
}

pub fn editMainTree(self: *@This(), buf: *const Buffer, edit: ts.InputEdit) !void {
    assert(self.trees.contains(buf));
    const list = self.trees.get(buf) orelse return;
    const tree = list.items[0];
    tree.edit(edit);
}

////////////////////////////////////////////////////////////////////////////////////////////// Query ID Selector

const DEFAULT_HIGHLIGHT_QUERIES: []const u8 = &.{0};

pub fn getHightlightQueryIndexes(self: *const @This(), buf: *Buffer) []const u8 {
    _ = self;
    _ = buf;
    return DEFAULT_HIGHLIGHT_QUERIES;
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Captures

pub fn initializeCapturesForMainTree(self: *@This(), buf: *Buffer, query_ids: []const u8) !void {
    const buf_tree_list = self.trees.get(buf) orelse unreachable;
    const tree = buf_tree_list.items[0];
    if (self.captures.getPtr(tree)) |capture_map| self.freeCaptureMap(capture_map);

    const captured_lines = try self.getCaptures(buf, tree, query_ids, 0, buf.getLineCount() - 1);
    var capture_map = CaptureMap{};
    try capture_map.put(self.a, query_ids.ptr, captured_lines);
    try self.captures.put(self.a, tree, capture_map);
}

fn freeCaptureMap(self: *@This(), capture_map: *CaptureMap) void {
    defer capture_map.deinit(self.a);
    var capture_map_iter = capture_map.valueIterator();
    while (capture_map_iter.next()) |list| {
        for (list.items) |line| {
            switch (line) {
                .std => |slice| self.a.free(slice),
                .long => |slice| self.a.free(slice),
            }
        }
        list.deinit(self.a);
    }
}

pub const CaptureID = u8;
pub const QueryID = u8;

const StdCapture = struct {
    start_col: u8,
    end_col: u8,
    query_id: QueryID,
    capture_id: CaptureID,
};
const LongCapture = struct {
    start_col: u32,
    end_col: u32,
    query_id: QueryID,
    capture_id: CaptureID,
};

pub const Captures = union(enum) {
    std: []const StdCapture,
    long: []const LongCapture,
};
const CapturedLines = std.ArrayListUnmanaged(Captures);

const CaptureMap = std.AutoHashMapUnmanaged([*]const u8, CapturedLines);

const MAX_INT_U32 = std.math.maxInt(u32);
const MAX_INT_U8 = std.math.maxInt(u8);

test {
    try eq(4, @sizeOf(StdCapture));
    try eq(12, @sizeOf(LongCapture));

    try eq(16, @sizeOf([]const StdCapture));
    try eq(24, @sizeOf(Captures));
}

fn getCaptures(self: *@This(), buf: *const Buffer, tree: *ts.Tree, query_ids: []const u8, start_line: u32, end_line: u32) !CapturedLines {
    const num_of_lines_to_process = end_line - start_line + 1;

    ///////////////////////////// precompute code paths

    const CodePath = enum { std, long };
    var code_paths = try self.a.alloc(CodePath, num_of_lines_to_process);
    defer self.a.free(code_paths);
    for (start_line..end_line + 1, 0..) |linenr, i| {
        const noc = buf.getNumOfCharsInLine(linenr);
        code_paths[i] = if (noc > MAX_INT_U8) .long else .std;
    }

    ///////////////////////////// set up containers

    var std_lines_list = try std.ArrayListUnmanaged(std.ArrayListUnmanaged(StdCapture)).initCapacity(self.a, num_of_lines_to_process);
    defer std_lines_list.deinit(self.a);
    for (start_line..end_line + 1) |_| try std_lines_list.append(self.a, std.ArrayListUnmanaged(StdCapture){});

    var long_lines_map = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(LongCapture)){};
    defer long_lines_map.deinit(self.a);

    ///////////////////////////// put things to containers

    const langsuite = try self.getLangSuite(.{ .language = tree.getLanguage() });
    for (query_ids) |query_id| {
        const sq = langsuite.queries.items[query_id];
        var cursor = try ts.Query.Cursor.create();
        defer cursor.destroy();
        cursor.execute(sq.query, tree.getRootNode());
        cursor.setPointRange(
            .{ .row = start_line, .column = 0 },
            .{ .row = end_line + 1, .column = 0 },
        );

        while (sq.nextMatch(cursor, buf)) |res| {
            const match = res.match orelse continue;
            assert(res.all_matched);

            for (match.captures()) |cap| {
                const capture_group_name = sq.query.getCaptureNameForId(cap.id);
                if (capture_group_name[0] == '_') continue;
                const start = cap.node.getStartPoint();
                const end = cap.node.getEndPoint();

                for (start.row..end.row + 1) |linenr| {
                    const idx = linenr - start_line;
                    switch (code_paths[idx]) {
                        .std => try std_lines_list.items[idx].append(self.a, StdCapture{
                            .query_id = query_id,
                            .capture_id = @intCast(cap.id),
                            .start_col = if (linenr == start.row) @intCast(start.column) else 0,
                            .end_col = if (linenr == end.row) @intCast(end.column) else MAX_INT_U8,
                        }),
                        .long => {
                            if (!long_lines_map.contains(@intCast(linenr))) try long_lines_map.put(self.a, @intCast(linenr), std.ArrayListUnmanaged(LongCapture){});
                            var list = long_lines_map.getPtr(@intCast(linenr)) orelse unreachable;
                            try list.append(self.a, LongCapture{
                                .query_id = query_id,
                                .capture_id = @intCast(cap.id),
                                .start_col = if (linenr == start.row) start.column else 0,
                                .end_col = if (linenr == end.row) end.column else MAX_INT_U32,
                            });
                        },
                    }
                }
            }
        }
    }

    ///////////////////////////// pack up containers

    var captured_lines = CapturedLines{};
    for (start_line..end_line + 1, 0..) |linenr, i| {
        switch (code_paths[i]) {
            .std => {
                std.mem.sort(StdCapture, std_lines_list.items[i].items, {}, captureLessThanStd);
                try captured_lines.append(self.a, .{ .std = try std_lines_list.items[i].toOwnedSlice(self.a) });
            },
            .long => {
                var list = long_lines_map.getPtr(@intCast(linenr)) orelse unreachable;
                std.mem.sort(LongCapture, list.items, {}, captureLessThanLong);
                try captured_lines.append(self.a, .{ .long = try list.toOwnedSlice(self.a) });
            },
        }
    }

    return captured_lines;
}

fn captureLessThanStd(_: void, a: StdCapture, b: StdCapture) bool {
    if (a.start_col < b.start_col) return true;
    if (a.start_col == b.start_col) return a.end_col < b.end_col;
    return false;
}

fn captureLessThanLong(_: void, a: LongCapture, b: LongCapture) bool {
    if (a.start_col < b.start_col) return true;
    if (a.start_col == b.start_col) return a.end_col < b.end_col;
    return false;
}

////////////////////////////////////////////////////////////////////////////////////////////// Captures Iterator

const MAX_CELL_OVERLAP_ASSUMPTION = 32;
pub const CaptureIterator = struct {
    capture_buf: [MAX_CELL_OVERLAP_ASSUMPTION]Capture = undefined,
    captures_start: u8 = 0,
    col: u32 = 0,

    pub const Capture = struct {
        query_id: QueryID,
        capture_id: CaptureID,
    };

    pub fn next(self: *@This(), captures: Captures) []Capture {
        defer self.col += 1;
        return switch (captures) {
            .std => |std_captures| self.next_(std_captures),
            .long => |long_captures| self.next_(long_captures),
        };
    }

    fn next_(self: *@This(), captures: anytype) []Capture {
        var ids_index: usize = 0;
        for (captures[self.captures_start..], 0..) |cap, i| {
            if (cap.start_col > self.col) break;
            if (cap.end_col <= self.col) {
                self.captures_start = @intCast(i + 1);
                continue;
            }
            self.capture_buf[ids_index] = Capture{ .capture_id = cap.capture_id, .query_id = cap.query_id };
            ids_index += 1;
        }

        return self.capture_buf[0..ids_index];
    }
};
