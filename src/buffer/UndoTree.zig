const UndoTree = @This();

const std = @import("std");
const RcNode = @import("RcRope.zig").RcNode;

const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

const Event = struct {
    node: RcNode,

    parent: ?*Event,
    children: *anyopaque,
    children_kind: enum { none, single, multiple },

    operation: Operation,
    operation_kind: enum { insert, delete },
};

const Operation = struct {
    start: CursorPoint,
    end: CursorPoint,
    chars: []const u8,
};

const CursorPoint = struct {
    line: u16,
    col: u16,
};

//////////////////////////////////////////////////////////////////////////////////////////////

test "some sizes" {
    try eq(8, @alignOf([]const u8));
    try eq(16, @sizeOf([]const u8));

    try eq(2, @alignOf(CursorPoint));
    try eq(4, @sizeOf(CursorPoint));

    try eq(8, @alignOf(Operation));
    try eq(24, @sizeOf(Operation));

    try eq(8, @sizeOf(RcNode));

    try eq(8, @alignOf(Event));
    try eq(56, @sizeOf(Event));
}
