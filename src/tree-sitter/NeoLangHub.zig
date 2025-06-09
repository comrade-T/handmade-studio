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

const Buffer = @import("NeoBuffer");

pub const ts = @import("bindings.zig");
pub const NeoStoredQuery = @import("NeoStoredQuery.zig");

pub const SupportedLanguage = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
langmap: std.AutoHashMapUnmanaged(*const ts.Language, NeoLangSuite) = .{},

treemap: std.AutoHashMapUnmanaged(*const Buffer, std.ArrayListUnmanaged(*ts.Tree)),

pub fn init(a: Allocator) !NeoLangHub {
    return NeoLangHub{ .a = a };
}

pub fn deinit(self: *@This()) void {
    var iter = self.langmap.valueIterator();
    while (iter.next()) |ls| ls.deinit(self.a);
    self.langmap.deinit();
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

    if (!self.map.contains(language)) {
        var langsuite = try NeoLangSuite.init(language);
        try langsuite.addDefaultHighlightQuery();
        try self.langmap.put(self.a, language, langsuite);
    }
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
        for (self.queries.items) |sq| sq.deinit();
        self.queries.deinit(a);
    }

    pub fn addDefaultHighlightQuery(self: *@This(), a: Allocator) !void {
        const pattern_string = switch (self.lang_choice) {
            .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
        };
        try self.addQuery(a, pattern_string);
    }

    pub fn addQuery(self: *@This(), a: Allocator, pattern_string: []const u8) !void {
        const language = try self.parser.getLanguage() orelse unreachable;
        const sq = try NeoStoredQuery.init(a, language, pattern_string);
        try self.queries.append(a, sq);
    }

    const ParseResult = struct {
        tree: *ts.Tree,
        changed_ranges: []const ts.Range = &.{},
    };

    fn parse(self: *@This(), buf: *const Buffer, may_old_tree: ?*ts.Tree, ranges: []const ts.Range) ParseResult {
        defer if (may_old_tree) |old_tree| old_tree.destroy();

        const parser = self.parser;
        defer parser.reset();
        parser.setIncludedRanges(ranges);

        const PARSE_BUFFER_SIZE = 1024;
        const ParseCtx = struct {
            buf: *Buffer,
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
        const new_tree = try parser.parse(may_old_tree, input);

        return ParseResult{
            .tree = new_tree,
            .changed_ranges = if (may_old_tree) |old_tree| old_tree.getChangedRanges(new_tree) else &.{},
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Parsing

pub fn editTree(self: *@This(), buf: *const Buffer, edit: ts.InputEdit) void {
    assert(self.buftreemap.contains(buf));
    const tree = self.buftreemap.get(buf) orelse return;
    tree.edit(edit);
}

pub fn parseBuffer(self: *@This(), buf: *const Buffer, lang_id: LanguageID) ![]const ts.Range {
    const may_old_tree = self.buftreemap.get(buf);
    const langsuite = try self.getLangSuite(lang_id);
    const parse_result = langsuite.parse(buf, may_old_tree, &.{});
    try self.buftreemap.put(self.a, buf, parse_result.tree);
    return parse_result.changed_ranges;
}

pub fn freeTSRanges(ranges: []const ts.Range) void {
    std.c.free(@as(*anyopaque, @ptrCast(@constCast(ranges.ptr))));
}

////////////////////////////////////////////////////////////////////////////////////////////// Injections

pub fn addInjection(self: *@This(), buf: *const Buffer, lang_id: LanguageID, ranges: []const ts.Range) !void {
    const langsuite = try self.getLangSuite(lang_id);
    const parse_result = langsuite.parse(buf, null, ranges);
    assert(parse_result.changed_ranges.len == 0);

    if (!self.injectmap.contains(buf)) {
        try self.injectmap.put(self.a, buf, std.ArrayListUnmanaged(*ts.Tree));
    }

    const list = self.injectmap.getPtr(buf) orelse unreachable;
    try list.append(self.a, parse_result.tree);
}

pub fn clearInjections(self: *@This(), buf: *const Buffer) void {
    const list = self.injectmap.getPtr(buf) orelse return;
    for (list.items) |tree| tree.destroy();
    list.deinit(self.a);
    _ = self.injectmap.remove(buf);
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Captures

const CaptureID = u8;
const QueryID = u8;

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

const Captures = union(enum) {
    std: []const StdCapture,
    long: []const LongCapture,
};
const CapturedLines = std.ArrayListUnmanaged(Captures);

const CapturesOfTreeMap = std.AutoHashMapUnmanaged(*const ts.Tree, CapturedLines);

const MAX_INT_U32 = std.math.maxInt(u32);
const MAX_INT_U8 = std.math.maxInt(u8);

test {
    try eq(4, @sizeOf(StdCapture));
    try eq(12, @sizeOf(LongCapture));

    try eq(16, @sizeOf([]const StdCapture));
    try eq(24, @sizeOf(Captures));
}

fn getCapturesForAllQueriesInTree(self: *@This(), buf: *const Buffer, tree: *const ts.Tree, start_line: u32, end_line: u32) !CapturesOfTreeMap {
    var result = CapturesOfTreeMap{};
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

    const langsuite = try self.getLangSuite(.{ .language = tree.getLanguage() });
    for (langsuite.queries.items, 0..) |sq, query_id| {

        ///////////////////////////// put things to containers

        var cursor = try ts.Query.Cursor.create();
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

                for (start.row..end.row + 1, 0..) |linenr, i| {
                    switch (code_paths[i]) {
                        .std => try std_lines_list.items[i].append(self.a, StdCapture{
                            .query_id = query_id,
                            .capture_id = @intCast(cap.id),
                            .start_col = if (linenr == start.row) @intCast(start.column) else 0,
                            .end_col = if (linenr == end.row) @intCast(end.column) else MAX_INT_U8,
                        }),
                        .long => {
                            if (!long_lines_map.contains(linenr)) try long_lines_map.put(self.a, linenr, std.ArrayListUnmanaged(LongCapture){});
                            var list = long_lines_map.getPtr(linenr) orelse unreachable;
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
                std.mem.sort(StdCapture, std_lines_list.items[i].items, {}, captureLessThan);
                captured_lines.append(self.a, .{ .std = try std_lines_list.items[i].toOwnedSlice() });
            },
            .long => {
                var list = long_lines_map.getPtr(linenr) orelse unreachable;
                std.mem.sort(StdCapture, list.items, {}, captureLessThan);
                captured_lines.append(self.a, .{ .long = try list.toOwnedSlice(self.a) });
            },
        }
    }
    try result.put(self.a, tree, captured_lines);

    return result;
}

fn captureLessThan(_: void, a: anytype, b: anytype) bool {
    if (a.start_col < b.start_col) return true;
    if (a.start_col == b.start_col) return a.end_col < b.end_col;
    return false;
}

////////////////////////////////////////////////////////////////////////////////////////////// Captures Iterator

const MAX_CELL_OVERLAP_ASSUMPTION = 32;
const CaptureIterator = struct {
    result_ids_buf: [MAX_CELL_OVERLAP_ASSUMPTION]Result = undefined,
    capture_starts: u8 = 0,
    col: u32 = 0,

    const Result = struct {
        query_id: QueryID,
        capture_id: CaptureID,
    };

    pub fn next(self: *@This()) ?[]Result {
        _ = self;
        // TODO:
    }
};
