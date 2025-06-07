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

pub const ts = @import("bindings.zig");
pub const NeoStoredQuery = @import("NeoStoredQuery.zig");

const ParseMan = @import("ParseMan.zig");
const Buffer = @import("NeoBuffer");

pub const SupportedLanguage = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
langmap: std.AutoHashMapUnmanaged(*const ts.Language, NeoLangSuite) = .{},
buftreemap: std.AutoHashMapUnmanaged(*const Buffer, *ts.Tree) = .{},

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
};

////////////////////////////////////////////////////////////////////////////////////////////// Parsing

pub fn editTree(self: *@This(), buf: *const Buffer, edit: ts.InputEdit) void {
    assert(self.buftreemap.contains(buf));
    const tree = self.buftreemap.get(buf) orelse return;
    tree.edit(edit);
}

pub fn parse(self: *@This(), buf: *const Buffer, lang_id: LanguageID) ?[]const ts.Range {
    assert(!self.buftreemap.contains(buf));
    const langsuite = try self.getLangSuite(lang_id);

    const may_old_tree = self.buftreemap.get(buf);
    defer if (may_old_tree) |old_tree| old_tree.destroy();

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
    const new_tree = try langsuite.parser.parse(may_old_tree, input);
    self.buftreemap.put(self.a, buf, new_tree);

    if (may_old_tree) |old_tree| return old_tree.getChangedRanges(new_tree);
    return null;
}

pub fn freeTSRanges(ranges: []const ts.Range) void {
    std.c.free(@as(*anyopaque, @ptrCast(@constCast(ranges.ptr))));
}
