const UndoTree = @This();

const std = @import("std");
const RcNode = @import("RcRope.zig").RcNode;

const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

const Event = struct {
    node: ?RcNode,

    parent: ?u16,
    children: union(enum) {
        none,
        single: u16,
        multiple: *ChildrenIndexList,
    },

    operation: Operation,
    operation_kind: OperationKind,
};

const ChildrenIndexList = std.ArrayList(u16);

const OperationKind = enum { insert, delete };

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

a: Allocator,
events: EventList,
current_event_index: ?u16 = null,

const EventList = std.MultiArrayList(Event);

//////////////////////////////////////////////////////////////////////////////////////////////

fn init(a: Allocator) !UndoTree {
    return UndoTree{
        .a = a,
        .events = EventList{},
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

fn setCurrentEventIndex(self: *UndoTree, i: u16) void {
    self.current_event_index = i;
}

fn addEvent(self: *UndoTree, node: ?RcNode, operation_kind: OperationKind, operation: Operation) !void {
    const event = Event{
        .node = node,
        .operation_kind = operation_kind,
        .operation = operation,
        .children = .none,
        .parent = self.current_event_index orelse null,
    };
    try self.events.append(self.a, event);

    const new_child_index: u16 = @intCast(self.events.len - 1);
    defer self.current_event_index = new_child_index;

    const parent_children = &self.events.items(.children)[self.current_event_index orelse return];
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

    try utree.addEvent(null, .insert, .{
        .start = .{ .line = 0, .col = 0 },
        .end = .{ .line = 0, .col = 5 },
        .chars = "hello",
    });
    try eq(1, utree.events.len);
    try eq(null, utree.events.get(0).parent);

    try utree.addEvent(null, .insert, .{
        .start = .{ .line = 0, .col = 5 },
        .end = .{ .line = 1, .col = 0 },
        .chars = "\n",
    });
    try eq(2, utree.events.len);
    try eq(0, utree.events.get(1).parent);
    try eq(1, utree.events.get(0).children.single);

    utree.setCurrentEventIndex(0);
    try utree.addEvent(null, .insert, .{
        .start = .{ .line = 0, .col = 5 },
        .end = .{ .line = 0, .col = 11 },
        .chars = " venus",
    });
    try eq(3, utree.events.len);
    try eq(0, utree.events.get(1).parent);
    try eq(0, utree.events.get(2).parent);
    try eqSlice(u16, &.{ 1, 2 }, utree.events.get(0).children.multiple.items);

    utree.setCurrentEventIndex(0);
    try utree.addEvent(null, .insert, .{
        .start = .{ .line = 0, .col = 11 },
        .end = .{ .line = 1, .col = 0 },
        .chars = "\n",
    });
    try eq(4, utree.events.len);
    try eq(0, utree.events.get(1).parent);
    try eq(0, utree.events.get(2).parent);
    try eq(0, utree.events.get(3).parent);
    try eqSlice(u16, &.{ 1, 2, 3 }, utree.events.get(0).children.multiple.items);
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
