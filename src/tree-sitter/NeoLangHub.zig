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

pub const SupportedLanguages = enum { zig };

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
map: std.AutoArrayHashMap(SupportedLanguages, NeoLangSuite),

pub fn init(a: Allocator) !NeoLangHub {
    return NeoLangHub{ .a = a, .map = std.AutoArrayHashMap(SupportedLanguages, *NeoLangSuite).init(a) };
}

pub fn deinit(self: *@This()) void {
    for (self.map.values()) |ls| ls.destroy();
    self.map.deinit();
}

pub fn get(self: *@This(), lang_choice: SupportedLanguages) !*NeoLangSuite {
    if (!self.map.contains(lang_choice)) {
        var ls = try NeoLangSuite.init(lang_choice);
        try ls.addDefaultHighlightQuery();
        try self.map.put(lang_choice, ls);
    }
    return self.map.get(lang_choice) orelse unreachable;
}

pub fn getLangChoiceFromFilePath(path: []const u8) ?SupportedLanguages {
    if (std.mem.endsWith(u8, path, ".zig")) return SupportedLanguages.zig;
    return null;
}

////////////////////////////////////////////////////////////////////////////////////////////// NeoLangSuite

const NeoLangSuite = struct {
    language: *const ts.Language,
    queries: std.ArrayListUnmanaged(NeoStoredQuery),

    pub fn init(lang_choice: SupportedLanguages) !NeoLangSuite {
        return NeoLangSuite{
            .language = switch (lang_choice) {
                .zig => try ts.Language.get("zig"),
            },
            .queries = .{},
        };
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
        const sq = try NeoStoredQuery.init(a, self.language, pattern_string);
        try self.queries.append(a, sq);
    }
};
