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
const assert = std.debug.assert;

const Buffer = @import("Buffer");
const InitFrom = Buffer.InitFrom;
const LangSuite = @import("LangSuite");
const LinkedList = @import("LinkedList.zig").LinkedList;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    var ls = try LangSuite.create(gpa, .zig);
    try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    var buf = try Buffer.create(gpa, .file, "src/window/old_window.zig");
    try buf.initiateTreeSitter(ls);
    defer buf.destroy();

    const entire_file = try buf.ropeman.toString(gpa, .lf);
    defer gpa.free(entire_file);

    /////////////////////////////

    const sq = ls.queries.get(LangSuite.DEFAULT_QUERY_ID).?;

    var cursor = try LangSuite.ts.Query.Cursor.create();
    cursor.execute(sq.query, buf.tstree.?.getRootNode());

    var targets_buf: [8]LangSuite.QueryFilter.CapturedTarget = undefined;
    var filter = ls.queries.get(LangSuite.DEFAULT_QUERY_ID).?.filter;
    {
        const zone = ztracy.ZoneNC(@src(), "keksure()", 0x00AAFF);
        defer zone.End();
        while (filter.nextMatch(entire_file, 0, &targets_buf, cursor)) |match| {
            _ = match;
        }
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

const max_int_u32 = std.math.maxInt(u32);
fn getCaptures(self: *@This()) !void {
    assert(self.ls != null and self.tree != null);
    const ls = self.ls orelse return;
    const tree = self.buf.tstree orelse return;

    const entire_file = try self.buf.ropeman.toString(self.a, .lf);
    defer self.a.free(entire_file);

    const num_of_lines = self.buf.ropeman.root.value.weights().bols;
    var lines_list = try ArrayList(std.ArrayListUnmanaged(StoredCapture)).initCapacity(self.a, num_of_lines);
    @memset(lines_list.items, std.ArrayListUnmanaged(StoredCapture){});

    for (ls.queries.values(), 0..) |sq, query_index| {
        var cursor = try LangSuite.ts.Query.Cursor.create();
        cursor.execute(sq.query, tree.getRootNode());

        var targets_buf: [8]LangSuite.QueryFilter.CapturedTarget = undefined;
        while (sq.filter.nextMatch(entire_file, 0, &targets_buf, cursor)) |match| {
            if (!match.all_predicates_matched) continue;
            for (match.targets) |target| {
                for (target.start_line..target.end_line + 1) |linenr| {
                    const cap = StoredCapture{
                        .query_idex = query_index,
                        .capture_id = target.capture_id,
                        .start_col = if (linenr == target.start_line) target.start_col else 0,
                        .end_col = if (linenr == target.end_col) target.end_col else max_int_u32,
                    };
                    lines_list.items[linenr].append(self.a, cap);
                }
            }
        }
    }

    // TODO:
}

//////////////////////////////////////////////////////////////////////////////////////////////

const StoredCapture = struct {
    query_idex: u16,
    capture_id: u16,
    start_col: u32,
    end_col: u32,
};

test {
    try eq(4, @alignOf(StoredCapture));
    try eq(12, @sizeOf(StoredCapture));
}
