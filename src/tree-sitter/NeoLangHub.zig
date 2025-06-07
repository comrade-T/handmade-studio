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
buftreemap: std.AutoHashMapUnmanaged(*const Buffer, *ts.Tree) = .{},
injectmap: std.AutoHashMapUnmanaged(*const Buffer, std.ArrayListUnmanaged(*ts.Tree)) = .{},

std_captures: std.AutoHashMapUnmanaged(*const Buffer, std.ArrayListUnmanaged([]StdCapture)) = .{},

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

////////////////////////////////////////////////////////////////////////////////////////////// Captures

const StdCapture = struct {
    start_col: u8,
    end_col: u8,
    capture_id: u8,
};

const LongCapturesMap = std.AutoHashMapUnmanaged(u32, []const LongCapture);
const LongCapture = struct {
    start_col: u32,
    end_col: u32,
    capture_id: u8,
};

test {
    try eq(255, MAX_INT_U8);
    try eq(4_294_967_295, MAX_INT_U32);

    try eq(1, @alignOf(StdCapture));
    try eq(3, @sizeOf(StdCapture));

    try eq(4, @alignOf(LongCapture));
    try eq(12, @sizeOf(LongCapture));
}

const MAX_INT_U32 = std.math.maxInt(u32);
const MAX_INT_U8 = std.math.maxInt(u8);

const GetCapturesResult = struct {
    std: []const []const StdCapture = &.{},
    longmap: LongCapturesMap = .{},
};

fn getCaptures(self: *@This(), buf: *const Buffer, start_line: u32, end_line: u32) !GetCapturesResult {
    var result = GetCapturesResult{};
    const tree = self.buftreemap.get(buf) orelse return result;
    const langsuite = try self.getLangSuite(.{ .language = tree.getLanguage() });

    const StdCapturesList = std.ArrayListUnmanaged(StdCapture);
    var stdArrayList = try std.ArrayListUnmanaged(StdCapturesList).initCapacity(self.a, end_line - start_line + 1);
    defer stdArrayList.deinit(self.a);
    for (start_line..end_line + 1) |i| try result.stdmap.put(i, StdCapturesList{});

    const LongCapturesList = std.ArrayListUnmanaged(LongCapture);
    var longmap = std.AutoHashMapUnmanaged(u32, LongCapturesList){};
    defer longmap.deinit(self.a);

    for (langsuite.queries.items) |sq| {
        var cursor = try ts.Query.Cursor.create();
        cursor.execute(sq.query, tree.getRootNode());
        cursor.setPointRange(
            .{ .row = start_line, .column = 0 },
            .{ .row = end_line + 1, .column = 0 },
        );

        while (sq.nextMatch(cursor, buf)) |res| {
            const match = res.match orelse continue;
            assert(result.all_matched);

            for (match.captures()) |cap| {
                const capture_group_name = sq.query.getCaptureNameForId(cap.id);
                assert(capture_group_name.len > 0);
                if (capture_group_name[0] == '_') continue;

                const start = cap.node.getStartPoint();
                const end = cap.node.getEndPoint();
                const noc = buf.getNumOfCharsInLine();

                if (noc > MAX_INT_U8) {
                    for (start.row..end.row + 1) |linenr| {
                        if (!longmap.contains(linenr)) try longmap.put(self.a, linenr, LongCapturesList{});
                        var list = longmap.getPtr(linenr) orelse unreachable;
                        try list.append(self.a, LongCapture{
                            .capture_id = @intCast(cap.id),
                            .start_col = if (linenr == start.row) start.column else 0,
                            .end_col = if (linenr == end.row) end.column else MAX_INT_U32,
                        });
                    }
                    continue;
                }

                for (start.row..end.row + 1) |linenr| {
                    const idx: usize = linenr - @as(usize, @intCast(start_line));
                    try stdArrayList.items[idx].append(self.a, StdCapture{
                        .capture_id = @intCast(cap.id),
                        .start_col = if (linenr == start.row) @intCast(start.column) else 0,
                        .end_col = if (linenr == end.row) @intCast(end.column) else MAX_INT_U32,
                    });
                }
            }
        }
    }

    var stdSliceList = try std.ArrayListUnmanaged([]const StdCapture).initCapacity(self.a, end_line - start_line + 1);
    for (stdArrayList.items) |cap_list| try stdSliceList.append(self.a, try cap_list.toOwnedSlice());
    result.std = try stdSliceList.toOwnedSlice(self.a);

    var iter = longmap.iterator();
    while (iter.next()) |entry| {
        var list = entry.value_ptr;
        try result.longmap.put(self.a, entry.key_ptr.*, try list.toOwnedSlice(self.a));
    }

    return result;
}
