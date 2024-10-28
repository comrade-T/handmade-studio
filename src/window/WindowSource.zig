const WindowSource = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const Buffer = @import("Buffer");
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
buf: *Buffer,

fn init(a: Allocator, buf: *Buffer) !WindowSource {
    const self = WindowSource{ .a = a, .buf = buf };
    return self;
}

fn deinit(self: *@This()) void {
    _ = self;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const TheLines = LinkedList(LineCaptures);

const LineCaptures = ArrayList(StoredCapture);

const StoredCapture = struct {
    capture_id: u16,
    start_col: u16,
    end_col: u16,
};

//////////////////////////////////////////////////////////////////////////////////////////////

const test_source = @embedFile("fixtures/dummy.zig");

test WindowSource {
    var ls = try LangSuite.create(testing_allocator, .zig);
    try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    var something = try WindowSource.init(testing_allocator, "fixtures/dummy.zig");
    defer something.deinit();

    {
        // TheSomething will become WindowSource
        // TODO: create buffer (either from string or from file)
        // TODO: create a WindowSource.initiateTreeSitter() method
        // TODO: if the created buffer is from file, depends on the file path, call WindowSource.initiateTreeSitter()
        // TODO: create a temporary function to return a LangSuite.SupportedLanguages enum variant from file path
    }
}
