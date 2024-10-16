const UndoTree = @This();

const std = @import("std");
const rcr = @import("RcRope.zig");
const RcNode = rcr.RcNode;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

//////////////////////////////////////////////////////////////////////////////////////////////

const CursorPoint = struct {
    line: u16 = 0,
    col: u16 = 0,
};

const CursorRange = struct {
    start: CursorPoint,
    end: CursorPoint,
};

const Event = struct {
    node: ?RcNode = null,
    parent: ?u16 = null,
    timestamp: i64,
    kind: Kind,
    children: Children,
    changes: Changes,

    const Kind = enum { insert, delete, replace };

    const Children = union(enum) {
        none,
        single: u16,
        multiple: *ArrayList(u16),
    };

    const Changes = union(enum) {
        none,
        single: Single,
        multiple: []Single,
        uniformed: Uniformed,

        const Single = struct {
            range: CursorRange,
            contents: []const u8,
        };

        const Uniformed = struct {
            ranges: []CursorRange,
            contents: []const u8,
        };
    };
};

test {
    try eq(.{ 8, 16 }, .{ @alignOf([]const u8), @sizeOf([]const u8) });
    try eq(.{ 8, 8 }, .{ @alignOf(RcNode), @sizeOf(RcNode) });
    try eq(.{ 8, 16 }, .{ @alignOf(?RcNode), @sizeOf(?RcNode) });
    try eq(.{ 2, 4 }, .{ @alignOf(CursorPoint), @sizeOf(CursorPoint) });
    try eq(.{ 2, 8 }, .{ @alignOf(CursorRange), @sizeOf(CursorRange) });
    try eq(.{ 8, 16 }, .{ @alignOf(Event.Children), @sizeOf(Event.Children) });
    try eq(.{ 8, 24 }, .{ @alignOf(Event.Changes.Single), @sizeOf(Event.Changes.Single) });
    try eq(.{ 8, 32 }, .{ @alignOf(Event.Changes.Uniformed), @sizeOf(Event.Changes.Uniformed) });
    try eq(.{ 8, 40 }, .{ @alignOf(Event.Changes), @sizeOf(Event.Changes) });
    try eq(.{ 8, 88 }, .{ @alignOf(Event), @sizeOf(Event) }); // 1000 events -> ~100kb
}
