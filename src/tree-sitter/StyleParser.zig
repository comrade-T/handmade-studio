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
const ztracy = @import("ztracy");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StringHashMap = std.StringHashMap;
const AutoArrayHashMap = std.AutoArrayHashMap;
const AutoHashMap = std.AutoHashMap;
const eql = std.mem.eql;

const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite.zig");
const ts = LangSuite.ts;
const CapturedTarget = LangSuite.QueryFilter.CapturedTarget;
const MatchResult = LangSuite.QueryFilter.MatchResult;
const MatchLimit = LangSuite.QueryFilter.MatchLimit;

////////////////////////////////////////////////////////////////////////////////////////////// StyleParser

a: Allocator,
query_ids_to_parse: StringHashMap(void),
coor_based_change_map: *CoorBasedChangeMap,

pub fn create(a: Allocator) !*StyleParser {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .query_ids_to_parse = StringHashMap(void).init(a),
        .coor_based_change_map = try CoorBasedChangeMap.create(a),
    };
    return self;
}

pub fn destroy(self: *@This()) void {
    self.coor_based_change_map.destroy();
    self.query_ids_to_parse.deinit();
    self.a.destroy(self);
}

pub fn addQuery(self: *@This(), query_id: []const u8) !void {
    try self.query_ids_to_parse.put(query_id, {});
}

pub fn parse(self: *@This(), ls: *LangSuite, tree: *ts.Tree, source: []const u8, noc_map: NumOfCharsInLineMap, may_limit: ?MatchLimit) !void {
    const zone = ztracy.ZoneNC(@src(), "StyleParser.parse()", 0x00AAFF);
    defer zone.End();

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

        var targets_buf: [8]CapturedTarget = undefined;
        while (sq.filter.nextMatch(source, offset, &targets_buf, cursor)) |match| {
            if (!match.all_predicates_matched) continue;
            try self.coor_based_change_map.addSingleMatch(query_id, match, noc_map);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// CoorBasedChangeMap

const NumOfCharsInLineMap = AutoArrayHashMap(LineIndex, ColumnIndex);

const PatternIndex = u16;
const LineIndex = u16;
const ColumnIndex = u16;
const PATTERN_INDEX_LIMIT = std.math.maxInt(PatternIndex);
const LINE_INDEX_LIMIT = std.math.maxInt(LineIndex);
const COLUMN_INDEX_LIMIT = std.math.maxInt(ColumnIndex);

const CoorBasedChangeMap = struct {
    a: Allocator,
    arena: ArenaAllocator,
    font_size: font_size_map_types.LineToCols,
    font_face: font_face_map_types.LineToCols,
    highlight_groups: highlight_group_map_types.LineToCols,

    const MapTypes = struct {
        LineToCols: type = undefined,
        ColToQueryIds: type = undefined,
        QueryIdToPatternIndexes: type = undefined,
        PatternIndexToChange: type = undefined,

        fn create(T: type) MapTypes {
            var self = MapTypes{};
            self.PatternIndexToChange = AutoArrayHashMap(PatternIndex, T);
            self.QueryIdToPatternIndexes = StringHashMap(self.PatternIndexToChange);
            self.ColToQueryIds = AutoHashMap(ColumnIndex, self.QueryIdToPatternIndexes);
            self.LineToCols = AutoHashMap(LineIndex, self.ColToQueryIds);
            return self;
        }
    };

    const font_size_map_types = MapTypes.create(f32);
    const font_face_map_types = MapTypes.create([]const u8);
    const highlight_group_map_types = MapTypes.create([]const u8);

    fn create(a: Allocator) !*CoorBasedChangeMap {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .arena = ArenaAllocator.init(a),
            .font_size = font_size_map_types.LineToCols.init(self.arena.allocator()),
            .font_face = font_face_map_types.LineToCols.init(self.arena.allocator()),
            .highlight_groups = highlight_group_map_types.LineToCols.init(self.arena.allocator()),
        };
        return self;
    }

    fn destroy(self: *@This()) void {
        self.arena.deinit();
        self.a.destroy(self);
    }

    ///////////////////////////// New

    fn addSingleMatch(self: *@This(), query_id: []const u8, match: MatchResult, noc_map: NumOfCharsInLineMap) !void {
        const zone = ztracy.ZoneNC(@src(), "CoorBasedChangeMap.addChanges()", 0xFFFF0F);
        defer zone.End();

        if (match.directives.len == 0) {
            for (match.targets) |target| {
                try self.addValues(query_id, &self.highlight_groups, highlight_group_map_types, match, target.name, target.name, noc_map);
            }
            return;
        }

        for (match.directives) |d| {
            switch (d) {
                .font_size => |fs| {
                    try self.addValues(query_id, &self.font_size, font_size_map_types, match, fs.capture, fs.value, noc_map);
                },
                .font => |font| {
                    try self.addValues(query_id, &self.font_size, font_size_map_types, match, font.capture, font.font_size, noc_map);
                    try self.addValues(query_id, &self.font_face, font_face_map_types, match, font.capture, font.font_face, noc_map);
                },
                else => {},
            }
        }
    }

    fn addValues(
        self: *@This(),
        query_id: []const u8,
        root_map: anytype,
        types: MapTypes,
        match: MatchResult,
        capture: []const u8,
        value: anytype,
        noc_map: NumOfCharsInLineMap,
    ) !void {
        const a = self.arena.allocator();

        for (match.targets) |target| {
            if (!eql(u8, target.name, capture)) continue;

            const start_point = target.node.getStartPoint();
            const end_point = target.node.getEndPoint();

            if (start_point.row > LINE_INDEX_LIMIT or end_point.row > LINE_INDEX_LIMIT or
                end_point.column > COLUMN_INDEX_LIMIT or end_point.column > COLUMN_INDEX_LIMIT) continue;

            for (start_point.row..end_point.row + 1) |linenr| {
                const casted_linenr: LineIndex = @intCast(linenr);

                if (!root_map.contains(casted_linenr)) {
                    try root_map.put(casted_linenr, types.ColToQueryIds.init(a));
                }
                const col_to_qids_map = root_map.getPtr(casted_linenr) orelse unreachable;

                const start_col = if (linenr == start_point.row) start_point.column else 0;
                const end_col = if (linenr == end_point.row)
                    end_point.column
                else
                    noc_map.get(casted_linenr) orelse start_col;

                for (start_col..end_col) |colnr| {
                    const casted_colnr: ColumnIndex = @intCast(colnr);

                    if (!col_to_qids_map.contains(casted_colnr)) {
                        try col_to_qids_map.put(casted_colnr, types.QueryIdToPatternIndexes.init(a));
                    }
                    const qid_to_pidxs_map = col_to_qids_map.getPtr(casted_colnr) orelse unreachable;

                    if (!qid_to_pidxs_map.contains(query_id)) {
                        try qid_to_pidxs_map.put(query_id, types.PatternIndexToChange.init(a));
                    }
                    const pidx_to_change_map = qid_to_pidxs_map.getPtr(query_id) orelse unreachable;

                    try pidx_to_change_map.put(match.pattern_index, value);
                }
            }
        }
    }
};

test CoorBasedChangeMap {
    var ls = try LangSuite.create(testing_allocator, .zig);
    // try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    try ls.addQuery("extra", extra_patterns_for_testing);

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
    const hl = style_parser.coor_based_change_map.highlight_groups;

    ///////////////////////////// Highlights

    { // line 1: `const Allocator = std.mem.Allocator;`
        try checkKeys(u16, &.{
            6,  7,  8,  9,  10, 11, 12, 13, 14,
            26, 27, 28, 29, 30, 31, 32, 33, 34,
        }, hl.get(1).?);
        try eqSlice(u16, &.{1}, hl.get(1).?.get(6).?.get("extra").?.keys());
        try eqSlice(u16, &.{1}, hl.get(1).?.get(34).?.get("extra").?.keys());
        try eqStr("type", hl.get(1).?.get(6).?.get("extra").?.get(1).?);
        try eqStr("type", hl.get(1).?.get(34).?.get("extra").?.get(1).?);
    }

    { // line 11: `fn callAddExample() void {`
        try checkKeys(u16, &.{
            3,  4,  5,  6,  7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
            20, 21, 22, 23,
        }, hl.get(11).?);
        try eqSlice(u16, &.{3}, hl.get(11).?.get(3).?.get("extra").?.keys());
        try eqStr("fn.name", hl.get(11).?.get(3).?.get("extra").?.get(3).?);
        try eqSlice(u16, &.{3}, hl.get(11).?.get(23).?.get("extra").?.keys());
        try eqStr("fn.return.type", hl.get(11).?.get(23).?.get("extra").?.get(3).?);
    }
}

const test_source = @embedFile("fixtures/predicates_test_dummy.zig");
const extra_patterns_for_testing =
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
    \\
    \\(
    \\  [
    \\    variable_type_function: (IDENTIFIER)
    \\    field_access: (IDENTIFIER)
    \\    parameter: (IDENTIFIER)
    \\  ] @type
    \\  (#match? @type "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
    \\)
    \\
    \\((IDENTIFIER) @x_y (#any-of? @x_y "x" "y"))
    \\
    \\(
    \\  FnProto
    \\    (IDENTIFIER) @fn.name (#eq? @fn.name "callAddExample")
    \\    _?
    \\    (ErrorUnionExpr
    \\      (SuffixExpr
    \\        (BuildinTypeExpr) @fn.return.type
    \\      )
    \\    )
    \\)
;

fn eqlStringSlices(expected: []const []const u8, got: []const []const u8) !void {
    try eq(expected.len, got.len);
    for (expected, 0..) |e, i| try eqStr(e, got[i]);
}

fn checkKeys(T: type, expected: []const T, map: anytype) !void {
    var keys_list = std.ArrayList(T).init(testing_allocator);
    var iter = map.keyIterator();
    while (iter.next()) |key| try keys_list.append(key.*);

    const keys = try keys_list.toOwnedSlice();
    defer testing_allocator.free(keys);
    std.mem.sort(T, keys, {}, std.sort.asc(T));

    try eqSlice(T, expected, keys);
}

pub fn produceNocMapForTesting(a: Allocator, source: []const u8) !NumOfCharsInLineMap {
    var map = NumOfCharsInLineMap.init(a);
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
