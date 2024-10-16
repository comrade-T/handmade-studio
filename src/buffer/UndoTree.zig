const UndoTree = @This();

const std = @import("std");
const RcNode = @import("RcRope.zig").RcNode;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
events: EventList,
current_event_index: u16 = 0,

const EventList = std.MultiArrayList(Event);

const Event = struct {
    node: ?RcNode = null,

    parent: ?u16 = null,
    children: union(enum) {
        none,
        single: u16,
        multiple: *ChildrenIndexList,
    },

    operation: Operation,
    operation_kind: OperationKind,
};

//////////////////////////////////////////////////////////////////////////////////////////////

fn init(a: Allocator) !UndoTree {
    var list = EventList{};
    try list.append(a, Event{ .children = .none, .operation_kind = .original, .operation = .{} });
    return UndoTree{
        .a = a,
        .events = list,
    };
}

fn deinit(self: *UndoTree) void {
    for (self.events.items(.children)) |c| {
        switch (c) {
            .multiple => |list| {
                list.deinit();
                self.a.destroy(list);
            },
            else => {},
        }
    }
    self.events.deinit(self.a);
}

fn setCurrentEventIndex(self: *UndoTree, target: u16) !ArrayList(u16) {
    const current = self.current_event_index;
    if (target == current) return ArrayList(u16).init(self.a);
    defer self.current_event_index = target;

    if (target < current) return try self.getTraversalList(current, target);

    const list = try self.getTraversalList(target, current);
    std.mem.sort(u16, list.items, {}, std.sort.asc(u16));
    return list;
}

fn getTraversalList(self: *UndoTree, descendant_index: u16, ancestor_index: u16) !ArrayList(u16) {
    assert(descendant_index > ancestor_index);
    assert(descendant_index < self.events.len and ancestor_index < self.events.len);
    var list = std.ArrayList(u16).init(self.a);
    var i: u16 = descendant_index;
    while (true) {
        try list.append(i);
        const parent_index = self.events.items(.parent)[i] orelse @panic("encountered null parent before reaching target");
        if (parent_index == ancestor_index) return list;
        i = parent_index;
    }
    unreachable;
}

test setCurrentEventIndex {
    var utree = try UndoTree.init(testing_allocator);
    defer utree.deinit();
    {
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 }, .chars = "h" });
        try eqSlice(?u16, &.{ null, 0 }, utree.events.items(.parent));
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 2 }, .chars = "e" });
        try eqSlice(?u16, &.{ null, 0, 1 }, utree.events.items(.parent));
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 3 }, .chars = "l" });
        try eqSlice(?u16, &.{ null, 0, 1, 2 }, utree.events.items(.parent));
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 }, .chars = "l" });
        try eqSlice(?u16, &.{ null, 0, 1, 2, 3 }, utree.events.items(.parent));
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 }, .chars = "o" });
        try eqSlice(?u16, &.{ null, 0, 1, 2, 3, 4 }, utree.events.items(.parent));
    }

    {
        var list = try utree.setCurrentEventIndex(0);
        defer list.deinit();
        try eqSlice(u16, &.{ 5, 4, 3, 2, 1 }, list.items);
    }
    {
        var list = try utree.setCurrentEventIndex(5);
        defer list.deinit();
        try eqSlice(u16, &.{ 1, 2, 3, 4, 5 }, list.items);
    }
    {
        var list = try utree.setCurrentEventIndex(2);
        defer list.deinit();
        try eqSlice(u16, &.{ 5, 4, 3 }, list.items);
    }
}

fn addEvent(self: *UndoTree, node: ?RcNode, operation_kind: OperationKind, operation: Operation) !void {
    const event = Event{
        .node = node,
        .operation_kind = operation_kind,
        .operation = operation,
        .children = .none,
        .parent = self.current_event_index,
    };
    try self.events.append(self.a, event);

    const new_child_index: u16 = @intCast(self.events.len - 1);
    defer self.current_event_index = new_child_index;

    const parent_children = &self.events.items(.children)[self.current_event_index];
    switch (parent_children.*) {
        .none => parent_children.* = .{ .single = new_child_index },
        .single => |single_child_index| {
            const list = try self.a.create(ChildrenIndexList);
            list.* = try ChildrenIndexList.initCapacity(self.a, 2);
            try list.append(single_child_index);
            try list.append(new_child_index);
            parent_children.* = .{ .multiple = list };
        },
        .multiple => try parent_children.*.multiple.append(new_child_index),
    }
}

test addEvent {
    var utree = try UndoTree.init(testing_allocator);
    defer utree.deinit();
    try eq(1, utree.events.len);
    try eq(null, utree.events.get(0).parent);

    {
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 }, .chars = "hello" });
        try eq(2, utree.events.len);
        try eq(0, utree.events.get(1).parent);
        try eq(1, utree.events.get(0).children.single);
    }

    {
        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 1, .col = 0 }, .chars = "\n" });
        try eq(3, utree.events.len);
        try eq(1, utree.events.get(2).parent);
        try eq(2, utree.events.get(1).children.single);
    }

    {
        var list = try utree.setCurrentEventIndex(1);
        defer list.deinit();
        try eq(utree.current_event_index, 1);
        try eqSlice(u16, &.{2}, list.items);

        try utree.addEvent(null, .insert, .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 0, .col = 11 }, .chars = " venus" });
        try eq(4, utree.events.len);
        try eq(1, utree.events.get(2).parent);
        try eq(1, utree.events.get(3).parent);
        try eqSlice(u16, &.{ 2, 3 }, utree.events.get(1).children.multiple.items);
    }
}

///////////////////////////// Load

fn loadBytesFromDisk(path: []const u8) []const u8 {
    _ = path;
}

fn fromBytes(bytes: []const u8) !*UndoTree {
    _ = bytes;
}

fn initFromFile(path: []const u8) !void {
    _ = path;
}

///////////////////////////// Save

fn serialize(self: *UndoTree) []const u8 {
    _ = self;
}

fn saveToDisk(bytes: []const u8, path: []const u8) !void {
    _ = bytes;
    _ = path;
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const ChildrenIndexList = std.ArrayList(u16);

const OperationKind = enum { original, insert, delete };

const Operation = struct {
    start: CursorPoint = .{},
    end: CursorPoint = .{},
    chars: []const u8 = "",
};

const CursorPoint = struct {
    line: u16 = 0,
    col: u16 = 0,
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    try eq(8, @alignOf([]const u8));
    try eq(16, @sizeOf([]const u8));

    try eq(2, @alignOf(CursorPoint));
    try eq(4, @sizeOf(CursorPoint));

    try eq(8, @alignOf(Operation));
    try eq(24, @sizeOf(Operation));

    try eq(8, @sizeOf(RcNode));

    try eq(8, @alignOf(Event));
    try eq(64, @sizeOf(Event));
}
