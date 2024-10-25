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

const LangSuite = @This();

const std = @import("std");
const ztracy = @import("ztracy");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const ts = @import("bindings.zig");
pub const QueryFilter = @import("QueryFilter.zig");
pub const StyleParser = @import("StyleParser.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

pub const SupportedLanguages = enum { zig };

a: Allocator,
lang_choice: SupportedLanguages,
language: *const ts.Language,
queries: QueryMap,

pub fn create(a: Allocator, lang_choice: SupportedLanguages) !*LangSuite {
    const self = try a.create(@This());
    const language = switch (lang_choice) {
        .zig => try ts.Language.get("zig"),
    };
    self.* = LangSuite{
        .a = a,
        .lang_choice = lang_choice,
        .language = language,
        .queries = QueryMap.init(a),
    };
    return self;
}

pub fn destroy(self: *@This()) void {
    for (self.queries.values()) |sq| {
        sq.filter.deinit();
        sq.query.destroy();
        self.a.free(sq.patterns);
        self.a.destroy(sq);
    }
    self.queries.deinit();
    self.a.destroy(self);
}

pub fn addDefaultHighlightQuery(self: *@This()) !void {
    const patterns = switch (self.lang_choice) {
        .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
    };
    try self.addQuery(DEFAULT_QUERY_ID, patterns);
}

pub fn addQuery(self: *@This(), id: []const u8, patterns: []const u8) !void {
    const zone = ztracy.ZoneNC(@src(), "Language.addQuery", 0x00AAFF);
    defer zone.End();

    const query = try ts.Query.create(self.language, patterns);
    const sq = try self.a.create(StoredQuery);
    sq.* = StoredQuery{
        .query = query,
        .patterns = try self.a.dupe(u8, patterns),
        .filter = try QueryFilter.init(self.a, query),
    };
    try self.queries.put(id, sq);
}

pub fn createParser(self: *@This()) !*ts.Parser {
    var parser = try ts.Parser.create();
    try parser.setLanguage(self.language);
    return parser;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const DEFAULT_QUERY_ID = "DEFAULT";

pub const QueryMap = std.StringArrayHashMap(*StoredQuery);
pub const StoredQuery = struct {
    query: *ts.Query,
    patterns: []const u8,
    filter: *QueryFilter,
};
