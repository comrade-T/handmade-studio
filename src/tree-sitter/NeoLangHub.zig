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

pub const ts = @import("bindings.zig");
pub const NeoStoredQuery = @import("NeoStoredQuery.zig");

pub const SupportedLanguage = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
map: std.AutoArrayHashMapUnmanaged(*const ts.Language, NeoLangSuite) = .{},

pub fn init(a: Allocator) !NeoLangHub {
    return NeoLangHub{ .a = a };
}

pub fn deinit(self: *@This()) void {
    for (self.map.values()) |ls| ls.destroy();
    self.map.deinit();
}

const GetLangSuiteRequest = union(enum) {
    language: *const ts.Language,
    lang_choice: SupportedLanguage,
};

pub fn getLangSuite(self: *@This(), req: GetLangSuiteRequest) !*NeoLangSuite {
    const language = switch (req) {
        .language => |lang| lang,
        .lang_choice => |lang_choice| switch (lang_choice) {
            .zig => try ts.Language.get("zig"),
        },
    };

    if (!self.map.contains(language)) {
        var langsuite = try NeoLangSuite.init(language);
        try langsuite.addDefaultHighlightQuery();
        try self.map.put(self.a, language, langsuite);
    }
    return self.map.getPtr(language) orelse unreachable;
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
