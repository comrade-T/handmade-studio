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

const WindowSource = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const Buffer = @import("Buffer");
const InitFrom = Buffer.InitFrom;
const LangSuite = @import("LangSuite");
const LinkedList = @import("LinkedList.zig").LinkedList;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    const total_start_time = std.time.milliTimestamp();
    defer {
        const total_end_time = std.time.milliTimestamp();
        const took = total_end_time - total_start_time;
        std.debug.print("took total: {d}\n", .{took});
    }

    /////////////////////////////

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    /////////////////////////////

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var ws = try WindowSource.init(gpa, .file, "src/window/old_window.zig", &lang_hub);
    defer ws.deinit();

    /////////////////////////////

    {
        const start_time = std.time.milliTimestamp();
        defer {
            const end_time = std.time.milliTimestamp();
            const took = end_time - start_time;
            std.debug.print("took: {d}\n", .{took});
        }
        try ws.getCapturesDemo();
        std.debug.print("done\n", .{});
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

from: InitFrom,
path: []const u8 = "",

buf: *Buffer,
ls: ?*LangSuite = null,
cap_list: CapList,

const CapList = LinkedList([]StoredCapture);

pub fn init(a: Allocator, from: InitFrom, source: []const u8, lang_hub: *LangSuite.LangHub) !WindowSource {
    var self = WindowSource{
        .a = a,
        .from = from,
        .buf = try Buffer.create(a, from, source),
        .cap_list = CapList.init(a),
    };
    if (from == .file) {
        self.path = source;
        try self.initiateTreeSitterForFile(lang_hub);
    }
    return self;
}

test init {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();
    {
        var ws = try WindowSource.init(testing_allocator, .string, "hello world", &lang_hub);
        defer ws.deinit();
        try eq(null, ws.buf.tstree);
        try eqStr("hello world", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));
    }
    {
        var ws = try WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_1_line.zig", &lang_hub);
        defer ws.deinit();
        try eqStr("const a = 10;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));
        try eqStr(
            \\source_file
            \\  Decl
            \\    VarDecl
            \\      "const"
            \\      IDENTIFIER
            \\      "="
            \\      ErrorUnionExpr
            \\        SuffixExpr
            \\          INTEGER
            \\      ";"
        , try ws.buf.tstree.?.getRootNode().debugPrint());
    }
}

pub fn deinit(self: *@This()) void {
    self.buf.destroy();
    { // cap list
        var current = self.cap_list.head;
        while (current) |node| {
            self.a.free(node.value);
            current = node.next;
        }
        self.cap_list.deinit();
    }
}

fn initiateTreeSitterForFile(self: *@This(), lang_hub: *LangSuite.LangHub) !void {
    const lang_choice = LangSuite.getLangChoiceFromFilePath(self.path) orelse return;
    self.ls = try lang_hub.get(lang_choice);
    try self.buf.initiateTreeSitter(self.ls.?);
}

////////////////////////////////////////////////////////////////////////////////////////////// getCaptures

const CapturedLinesMap = std.AutoArrayHashMap(usize, StoredCaptureList);
const StoredCaptureList = std.ArrayListUnmanaged(StoredCapture);
const max_int_u32 = std.math.maxInt(u32);

fn getCaptures(self: *@This(), entire_file: []const u8, start: usize, end: usize) !CapturedLinesMap {
    assert(self.ls != null and self.buf.tstree != null);

    var map = CapturedLinesMap.init(self.a);
    const ls = self.ls orelse return map;
    const tree = self.buf.tstree orelse return map;

    for (start..end + 1) |i| try map.put(i, try StoredCaptureList.initCapacity(self.a, 8));

    for (ls.queries.values(), 0..) |sq, query_index| {
        var cursor = try LangSuite.ts.Query.Cursor.create();
        cursor.execute(sq.query, tree.getRootNode());
        cursor.setPointRange(
            .{ .row = @intCast(start), .column = 0 },
            .{ .row = @intCast(end + 1), .column = 0 },
        );

        var targets_buf: [8]LangSuite.QueryFilter.CapturedTarget = undefined;
        while (sq.filter.nextMatch(entire_file, 0, &targets_buf, cursor)) |match| {
            if (!match.all_predicates_matched) continue;
            for (match.targets) |target| {
                for (target.start_line..target.end_line + 1) |linenr| {
                    const cap = StoredCapture{
                        .query_index = @intCast(query_index),
                        .capture_id = target.capture_id,
                        .start_col = if (linenr == target.start_line) target.start_col else 0,
                        .end_col = if (linenr == target.end_line) target.end_col else max_int_u32,
                    };
                    var list = map.getPtr(linenr) orelse continue;
                    try list.append(self.a, cap);
                }
            }
        }
    }

    for (map.values()) |list| std.mem.sort(StoredCapture, list.items, {}, StoredCapture.lessThan);
    return map;
}

test getCaptures {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    {
        var ws = try WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
        defer ws.deinit();

        const source = try ws.buf.ropeman.toString(testing_allocator, .lf);
        defer testing_allocator.free(source);
        try eqStr(
            \\const a = 10;
            \\var not_false = true;
            \\
        , source);

        const first_line_matches: []const StoredCapture = &.{
            .{ .start_col = 0, .end_col = 5, .query_index = 0, .capture_id = 28 }, // @type.qualifier
            .{ .start_col = 6, .end_col = 7, .query_index = 0, .capture_id = 2 }, // @variable
            .{ .start_col = 10, .end_col = 12, .query_index = 0, .capture_id = 12 }, // number
            .{ .start_col = 12, .end_col = 13, .query_index = 0, .capture_id = 33 }, // punctuation.delimiter
        };
        const second_line_matches: []const StoredCapture = &.{
            .{ .start_col = 0, .end_col = 3, .query_index = 0, .capture_id = 28 }, // @type.qualifier
            .{ .start_col = 4, .end_col = 13, .query_index = 0, .capture_id = 2 }, // @variable
            .{ .start_col = 16, .end_col = 20, .query_index = 0, .capture_id = 14 }, // boolean
            .{ .start_col = 20, .end_col = 21, .query_index = 0, .capture_id = 33 }, // punctuation.delimiter
        };

        try eqStr("type.qualifier", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(28));
        try eqStr("variable", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(2));
        try eqStr("number", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(12));
        try eqStr("boolean", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(14));
        try eqStr("punctuation.delimiter", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(33));

        { // entire file
            var map = try ws.getCaptures(source, 0, ws.buf.ropeman.root.value.weights().bols - 1);
            defer {
                for (map.values()) |*list| list.deinit(testing_allocator);
                map.deinit();
            }

            try eq(3, map.keys().len);
            try eqSlice(StoredCapture, first_line_matches, map.get(0).?.items);
            try eqSlice(StoredCapture, second_line_matches, map.get(1).?.items);
            try eqSlice(StoredCapture, &.{}, map.get(2).?.items);
        }

        { // only 1st line
            var map = try ws.getCaptures(source, 0, 0);
            defer {
                for (map.values()) |*list| list.deinit(testing_allocator);
                map.deinit();
            }

            try eq(1, map.keys().len);
            try eqSlice(StoredCapture, first_line_matches, map.get(0).?.items);
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const StoredCapture = struct {
    query_index: u16,
    capture_id: u16,
    start_col: u32,
    end_col: u32,

    fn lessThan(_: void, a: StoredCapture, b: StoredCapture) bool {
        if (a.start_col < b.start_col) return true;
        if (a.start_col == b.start_col) return a.end_col < b.end_col;
        return false;
    }
};

test {
    try eq(4, @alignOf(StoredCapture));
    try eq(12, @sizeOf(StoredCapture));
}
