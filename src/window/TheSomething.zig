const TheSomething = @This();
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
const LinkedList = @import("LinkedList.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
buf: *Buffer,

fn init(a: Allocator, buf: *Buffer) !TheSomething {
    const self = TheSomething{ .a = a, .buf = buf };
    return self;
}

fn deinit(self: *@This()) void {
    _ = self;
}

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

const test_source = @embedFile("fixtures/dummy.zig");

test TheSomething {
    var ls = try LangSuite.create(testing_allocator, .zig);
    try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    var buf = try Buffer.create(testing_allocator, .string, test_source);
    defer buf.destroy();

    var something = try TheSomething.init(testing_allocator, buf);
    defer something.deinit();

    {
        // TODO:
    }
}
