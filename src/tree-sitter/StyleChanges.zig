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

const StyleChanges = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const AutoArrayHashMap = std.AutoArrayHashMap;
const AutoHashMap = std.AutoHashMap;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite");
const ts = LangSuite.ts;

////////////////////////////////////////////////////////////////////////////////////////////// init()

// a: Allocator,
// font_size: LineToCols_FontSize,
//
// pub fn create(a: Allocator, ls: *const LangSuite, tree: *ts.Tree, excludes: []QueryExclusion) !*StyleChanges {
//     const self = try a.create(@This());
//     self.* = .{
//         .a = a,
//         .font_size = LineToCols_FontSize.init(a),
//     };
//     return self;
// }
//
// pub fn destroy(self: *@This()) void {
//     self.a.destroy(self);
// }
//
// fn addChangesToMap(self: *@This(), ls: *const LangSuite, tree: *ts.Tree, excludes: []QueryExclusion) !void {
//     var iter = ls.queries.iterator();
//     while (iter.next()) |entry| {
//         // TODO:
//     }
// }

////////////////////////////////////////////////////////////////////////////////////////////// Types

// font-size
const LineToCols_FontSize = AutoArrayHashMap(usize, ColToPatterns_FontSize);
const ColToPatterns_FontSize = std.StringArrayHashMap(PatternIndexToChange_FontSize);
const PatternIndexToChange_FontSize = AutoArrayHashMap(usize, f32);

////////////////////////////////////////////////////////////////////////////////////////////// ExcludeMap

pub const ExcludeMap = struct {
    const QueryIDToPatternIndexSet = StringHashMap(union(enum) { all, some: PatternIndexSet });
    const PatternIndexSet = AutoHashMap(usize, void);

    a: Allocator,
    map: QueryIDToPatternIndexSet,

    pub fn init(a: Allocator) !ExcludeMap {
        return ExcludeMap{ .a = a, .map = QueryIDToPatternIndexSet.init(a) };
    }

    pub fn deinit(self: *@This()) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |value| if (value.* == .some) value.*.some.deinit();
        self.map.deinit();
    }

    pub fn excludeEntireQuery(self: *@This(), query_id: []const u8) !void {
        try self.map.put(query_id, .all);
    }

    pub fn excludePatternIndexOfQuery(self: *@This(), query_id: []const u8, pattern_index: usize) !void {
        if (self.map.get(query_id) == null) try self.map.put(query_id, .{ .some = PatternIndexSet.init(self.a) });
        if (self.map.getPtr(query_id)) |either_type| {
            switch (either_type.*) {
                .all => std.debug.print("excludePatternIndexOfQuery() was called, but the value for query_id '{s}' is already .all --> ignoring.\n", .{query_id}),
                .some => try either_type.*.some.put(pattern_index, {}),
            }
        }
    }

    test ExcludeMap {
        var exclude_map = try ExcludeMap.init(testing_allocator);
        defer exclude_map.deinit();

        try exclude_map.excludeEntireQuery("DEFAULT");
        try exclude_map.excludePatternIndexOfQuery("extra", 1);
        try exclude_map.excludePatternIndexOfQuery("extra", 5);

        try eq(.all, exclude_map.map.get("DEFAULT").?);
        try eq(null, exclude_map.map.get("doesnt_exist"));
        try eq({}, exclude_map.map.get("extra").?.some.get(1).?);
        try eq({}, exclude_map.map.get("extra").?.some.get(5).?);
        try eq(null, exclude_map.map.get("extra").?.some.get(0));
    }
};

const QueryExclusion = struct {
    id: []const u8,
    exclude_patterns: union(enum) { all, some: []usize },
};

////////////////////////////////////////////////////////////////////////////////////////////// Tests

const test_source = @embedFile("fixtures/predicates_test_dummy.zig");

// test {
//     var ls = try LangSuite.create(testing_allocator, .zig);
//     // try ls.addDefaultHighlightQuery();
//     defer ls.destroy();
//
//     const extra_patterns =
//         \\(
//         \\  FnProto
//         \\    (IDENTIFIER) @fn_name (#not-eq? @fn_name "callAddExample") (#font-size! @fn_name 60)
//         \\    _?
//         \\    (ErrorUnionExpr
//         \\      (SuffixExpr
//         \\        (BuildinTypeExpr) @return_type
//         \\        (#font! @return_type "Inter" 80)
//         \\      )
//         \\    )
//         \\)
//     ;
//     try ls.addQuery("extra", extra_patterns);
//
//     // parsing
//     var parser = try ls.createParser();
//     defer parser.destroy();
//     const tree = try parser.parseString(null, test_source);
//
//     // cursor
//     const changes = try StyleChanges.init(testing_allocator, ls, tree, &.{});
//
//     try eq(2, changes.font_size.keys().len);
// }

test {
    std.testing.refAllDeclsRecursive(StyleChanges);
}
