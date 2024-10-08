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

const StyleParser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StringHashMap = std.StringHashMap;
const AutoArrayHashMap = std.AutoArrayHashMap;
const AutoHashMap = std.AutoHashMap;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite");
const ts = LangSuite.ts;
const MatchResult = LangSuite.QueryFilter.MatchResult;
const MatchLimit = LangSuite.QueryFilter.MatchLimit;

////////////////////////////////////////////////////////////////////////////////////////////// StyleParser

a: Allocator,
query_ids_to_parse: StringHashMap(void),
change_map: *ChangeMap,

pub fn create(a: Allocator) !*StyleParser {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .query_ids_to_parse = StringHashMap(void).init(a),
        .change_map = try ChangeMap.create(a),
    };
    return self;
}

pub fn destroy(self: *@This()) void {
    self.change_map.destroy();
    self.query_ids_to_parse.deinit();
    self.a.destroy(self);
}

pub fn addQuery(self: *@This(), query_id: []const u8) !void {
    try self.query_ids_to_parse.put(query_id, {});
}

pub fn parse(self: *@This(), ls: *LangSuite, tree: *ts.Tree, source: []const u8, noc_map: ChangeMap.NumOfCharsInLineMap, may_limit: ?MatchLimit) !void {
    var iter = ls.queries.iterator();
    while (iter.next()) |entry| {
        const query_id = entry.key_ptr.*;
        if (self.query_ids_to_parse.get(query_id) == null) continue;

        const sq = entry.value_ptr.*;
        const cursor = try ts.Query.Cursor.create();
        const offset = if (may_limit) |l| l.offset else 0;
        if (may_limit) |limit| cursor.setPointRange(
            ts.Point{ .row = @intCast(limit.start_line), .column = 0 },
            ts.Point{ .row = @intCast(limit.end_line + 1), .column = 0 },
        );
        cursor.execute(sq.query, tree.getRootNode());
        const matches = try sq.filter.getAllMatches(self.a, source, offset, cursor);
        defer {
            for (matches) |m| self.a.free(m.targets);
            testing_allocator.free(matches);
        }

        try self.change_map.addChanges(query_id, matches, noc_map);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// ChangeMap

const ChangeMap = struct {
    a: Allocator,
    arena: ArenaAllocator,
    font_size: QueryIdToPatternIndexes_FontSize,

    const NumOfCharsInLineMap = AutoArrayHashMap(LineIndex, ColumnIndex);

    const PatternIndex = u16;
    const LineIndex = u16;
    const ColumnIndex = u16;
    const PATTERN_INDEX_LIMIT = std.math.maxInt(PatternIndex);
    const LINE_INDEX_LIMIT = std.math.maxInt(LineIndex);
    const COLUMN_INDEX_LIMIT = std.math.maxInt(ColumnIndex);

    const QueryIdToPatternIndexes_FontSize = StringHashMap(PatternIndexToLine_FontSize);
    const PatternIndexToLine_FontSize = AutoArrayHashMap(PatternIndex, LineToCols_FontSize);
    const LineToCols_FontSize = AutoArrayHashMap(LineIndex, ColToChange_FontSize);
    const ColToChange_FontSize = AutoArrayHashMap(ColumnIndex, f32);

    // change_map.font_size.get("extra").?.get(pattern_index: 0).?.get(linenr: 0).?.get(colnr: 0);

    fn create(a: Allocator) !*ChangeMap {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .arena = ArenaAllocator.init(a),
            .font_size = QueryIdToPatternIndexes_FontSize.init(self.arena.allocator()),
        };
        return self;
    }

    fn destroy(self: *@This()) void {
        self.arena.deinit();
        self.a.destroy(self);
    }

    fn addChanges(self: *@This(), query_id: []const u8, matches: []MatchResult, noc_map: NumOfCharsInLineMap) !void {
        if (!self.font_size.contains(query_id)) {
            try self.font_size.put(query_id, PatternIndexToLine_FontSize.init(self.arena.allocator()));
        }
        var pi_to_line_map = self.font_size.getPtr(query_id) orelse unreachable;

        for (matches) |match| {
            // // if there are no directives in the pattern, treat it as highlight
            // if (match.directives.len == 0) {
            //     // TODO:
            // }

            for (match.directives) |d| {
                if (!pi_to_line_map.contains(match.pattern_index)) {
                    try pi_to_line_map.put(match.pattern_index, LineToCols_FontSize.init(self.arena.allocator()));
                }
                var line_to_col_map = pi_to_line_map.getPtr(match.pattern_index) orelse unreachable;

                switch (d) {
                    .font_size => |font_size_directive| {
                        for (match.targets) |target| {
                            if (eql(u8, target.name, font_size_directive.capture)) {
                                const start_point = target.node.getStartPoint();
                                const end_point = target.node.getEndPoint();
                                if (start_point.row > LINE_INDEX_LIMIT or end_point.row > LINE_INDEX_LIMIT or
                                    end_point.column > COLUMN_INDEX_LIMIT or end_point.column > COLUMN_INDEX_LIMIT) continue;

                                for (start_point.row..end_point.row + 1) |linenr| {
                                    const casted_linenr: LineIndex = @intCast(linenr);

                                    if (!line_to_col_map.contains(casted_linenr)) {
                                        try line_to_col_map.put(casted_linenr, ColToChange_FontSize.init(self.arena.allocator()));
                                    }
                                    var col_to_change_map = line_to_col_map.getPtr(casted_linenr) orelse unreachable;

                                    const start_col = if (linenr == start_point.row) start_point.column else 0;
                                    const end_col = if (linenr == end_point.row)
                                        end_point.column
                                    else
                                        noc_map.get(casted_linenr) orelse start_col;

                                    for (start_col..end_col) |colnr| {
                                        try col_to_change_map.put(@intCast(colnr), font_size_directive.value);
                                    }
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// ExcludeMap

pub const ExcludeMap = struct {
    const ExcludeStatus = union(enum) { all, some: PatternIndexSet };
    const QueryIDToPatternIndexSet = StringHashMap(ExcludeStatus);
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

    pub fn getPtr(self: *@This(), query_id: []const u8) ?*ExcludeStatus {
        return self.map.getPtr(query_id);
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

////////////////////////////////////////////////////////////////////////////////////////////// Tests

const test_source = @embedFile("fixtures/predicates_test_dummy.zig");

test {
    var ls = try LangSuite.create(testing_allocator, .zig);
    // try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    const extra_patterns =
        \\(
        \\  FnProto
        \\    (IDENTIFIER) @fn_name (#not-eq? @fn_name "callAddExample") (#font-size! @fn_name 60)
        \\    _?
        \\    (ErrorUnionExpr
        \\      (SuffixExpr
        \\        (BuildinTypeExpr) @return_type
        \\        (#font! @return_type "Inter" 80)
        \\      )
        \\    )
        \\)
    ;
    try ls.addQuery("extra", extra_patterns);

    var parser = try ls.createParser();
    defer parser.destroy();
    const tree = try parser.parseString(null, test_source);

    /////////////////////////////

    var style_parser = try StyleParser.create(testing_allocator);
    defer style_parser.destroy();
    try style_parser.addQuery("extra");

    var noc_map = try produceNocMapForTesting(testing_allocator, test_source);
    defer noc_map.deinit();

    try style_parser.parse(ls, tree, test_source, noc_map, null);
    const change_map = style_parser.change_map;

    try eq(true, change_map.font_size.get("extra") != null);
    try eqSlice(u16, &.{0}, change_map.font_size.get("extra").?.keys());
    try eqSlice(u16, &.{ 3, 7 }, change_map.font_size.get("extra").?.get(0).?.keys());
    try eqSlice(u16, &.{ 3, 4, 5 }, change_map.font_size.get("extra").?.get(0).?.get(3).?.keys());
    try eqSlice(f32, &.{ 60, 60, 60 }, change_map.font_size.get("extra").?.get(0).?.get(3).?.values());
    try eqSlice(u16, &.{ 3, 4, 5 }, change_map.font_size.get("extra").?.get(0).?.get(7).?.keys());
    try eqSlice(f32, &.{ 60, 60, 60 }, change_map.font_size.get("extra").?.get(0).?.get(7).?.values());
}

fn produceNocMapForTesting(a: Allocator, source: []const u8) !ChangeMap.NumOfCharsInLineMap {
    var map = ChangeMap.NumOfCharsInLineMap.init(a);
    var split_iter = std.mem.split(u8, source, "\n");
    var i: usize = 0;
    while (split_iter.next()) |line| {
        defer i += 1;
        try map.put(@intCast(i), @intCast(line.len));
    }
    return map;
}

test {
    std.testing.refAllDeclsRecursive(StyleParser);
}
