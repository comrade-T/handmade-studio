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
lang_hub: *LangSuite.LangHub,
path: ?[]const u8 = null,
buf: *Buffer,
from: InitFrom,

pub fn init(a: Allocator, from: InitFrom, source: []const u8, lang_hub: *LangSuite.LangHub) !WindowSource {
    var self = WindowSource{
        .a = a,
        .from = from,
        .buf = try Buffer.create(a, from, source),
        .lang_hub = lang_hub,
    };
    if (from == .file) {
        self.path = source;
        try self.initiateTreeSitterForFile();
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

fn initiateTreeSitterForFile(self: *@This()) !void {
    const lang_choice = LangSuite.getLangChoiceFromFilePath(self.path orelse return) orelse return;
    try self.initiateTreeSitter(lang_choice);
}

pub fn initiateTreeSitter(self: *@This(), lang_choice: LangSuite.SupportedLanguages) !void {
    try self.buf.initiateTreeSitter(try self.lang_hub.get(lang_choice));
}

pub fn deinit(self: *@This()) void {
    self.buf.destroy();
}

//////////////////////////////////////////////////////////////////////////////////////////////

const TheLines = LinkedList(LineCaptures);

const LineCaptures = ArrayList(StoredCapture);

const StoredCapture = struct {
    capture_id: u16,
    start_col: u16,
    end_col: u16,
};
