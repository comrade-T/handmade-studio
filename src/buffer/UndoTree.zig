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

events: EventList,

pending: EventList,
pending_str_arena: ArenaAllocator,

current_event_index: u16 = 0,

//////////////////////////////////////////////////////////////////////////////////////////////

fn init(a: Allocator) !UndoTree {
    var events = EventList{};
    try events.append(a, Event{
        .timestamp = std.time.milliTimestamp(),
        .children = .none,
        .kind = .original,
        .changes = .none,
    });
    return UndoTree{
        .a = a,
        .events = events,
        .pending = EventList{},
        .pending_str_arena = ArenaAllocator.init(a),
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
    self.pending_str_arena.deinit();
    self.pending.deinit(self.a);
    self.events.deinit(self.a);
}

////////////////////////////////////////////////////////////////////////////////////////////// WIP

fn addPendingEvent(self: *UndoTree, node: ?RcNode, kind: Event.Kind, mod: Event.Modification) !void {
    const duped_chars = try self.pending_str_arena.allocator().dupe(u8, mod.chars);
    const modification = Event.Modification{ .start = mod.start, .end = mod.end, .chars = duped_chars };
    const event = Event{
        .node = node,
        .timestamp = std.time.milliTimestamp(),
        .kind = kind,
        .changes = .{ .single = modification },
        .children = .none,
        .parent = self.current_event_index,
    };
    try self.pending.append(self.a, event);
}

fn beginMultiCursorEdit() !void {
    // TODO:
}

fn updateMultiCursorEdit() !void {
    // TODO:
}

fn endMultiCursorEdit() !void {
    // TODO:
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CursorRange = struct {
    start: CursorPoint,
    end: CursorPoint,
};

const ConsecutiveMultiCursorInsertEvent = struct {
    chars_list: ArrayList(u8),
    ranges: ArrayList(CursorRange),

    fn init(a: Allocator) !ConsecutiveMultiCursorInsertEvent {
        return ConsecutiveMultiCursorInsertEvent{
            .chars_list = ArrayList(u8).init(a),
            .ranges = ArrayList(CursorRange).init(a),
        };
    }

    fn deinit(self: *@This()) void {
        self.chars_list.deinit();
        self.ranges.deinit();
    }

    fn addRange(self: *@This(), range: CursorRange) !void {
        self.ranges.appendSlice(range);
    }

    fn addChars(self: *@This(), chars: []const u8, line_inc: u16, col_inc: u16) !void {
        self.chars_list.appendSlice(chars);
        for (0..self.ranges.items) |i| {
            self.ranges.items[i].end.line += line_inc;
            self.ranges.items[i].end.col += col_inc;
        }
    }

    fn finalize(self: *@This(), a: Allocator, node: RcNode) !Event {
        defer self.deinit();

        var modifications = ArrayList(Event.Modification).init(a);
        for (self.ranges.items) |r| {
            const mod = Event.Modification{
                .start = r.start,
                .end = r.end,
                .chars = a.dupe(u8, self.chars_list),
            };
            try modifications.append(mod);
        }

        // TODO: how do I make it singular?

        return Event{
            .node = node,
            .timestamp = std.time.milliTimestamp(),
            .kind = .insert,
            .children = .none,
            .parent = self.current_event_index,
            .changes = .{ .multiple = try modifications.toOwnedSlice() },
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// WIP 2

fn beginSingleCursorEdit() !void {
    // TODO:
}

fn updateSingleCursorEdit() !void {
    // TODO:
}

fn endSingleCursorEdit() !void {
    // TODO:
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn addPendingEvent_Old(self: *UndoTree, node: ?RcNode, kind: Event.Kind, changes: Event.Changes) !void {
    const event = Event{
        .node = node,
        .timestamp = std.time.milliTimestamp(),
        .kind = kind,
        .changes = changes,
        .children = .none,
        .parent = self.current_event_index,
    };
    try self.pending.append(self.a, event);
}

test addPendingEvent_Old {
    var utree = try UndoTree.init(testing_allocator);
    defer utree.deinit();

    try utree.addPendingEvent_Old(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 }, .chars = "h" } });
    try utree.addPendingEvent_Old(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 2 }, .chars = "e" } });
    try utree.addPendingEvent_Old(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 3 }, .chars = "l" } });
    try utree.addPendingEvent_Old(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 }, .chars = "l" } });
    try utree.addPendingEvent_Old(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 }, .chars = "o" } });
    try eq(1, utree.events.len);
    try eq(5, utree.pending.len);

    // TODO: how the fuck do I join those updates together?
    // TODO: let alone multi cursors
}

fn upgradeLatestPendingEventToUndoEvent(self: *UndoTree) !void {
    assert(self.pending.len > 0);
    if (self.pending.len == 0) return;
    try self.events.append(self.a, self.pending.get(self.pending.len - 1));
    try self.updateCurrentIndexAfterAppend();
    self.cleanUpPendingEvents();
}

fn cleanUpPendingEvents(self: *UndoTree) void {
    for (0..self.pending.len - 1) |i| {
        const node = self.pending.items(.node)[i];
        assert(node != null);
        if (node) |n| rcr.freeRcNode(n);
    }
    self.pending.deinit(self.a);
    self.pending = EventList{};
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn addUndoEvent(self: *UndoTree, node: ?RcNode, kind: Event.Kind, changes: Event.Changes) !void {
    const event = self.createEvent(node, kind, changes);
    try self.events.append(self.a, event);
    try self.updateCurrentIndexAfterAppend();
}

test addUndoEvent {
    var utree = try UndoTree.init(testing_allocator);
    defer utree.deinit();
    try eq(1, utree.events.len);
    try eq(null, utree.events.get(0).parent);

    {
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 }, .chars = "hello" } });
        try eq(2, utree.events.len);
        try eq(0, utree.events.get(1).parent);
        try eq(1, utree.events.get(0).children.single);
    }

    {
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 1, .col = 0 }, .chars = "\n" } });
        try eq(3, utree.events.len);
        try eq(1, utree.events.get(2).parent);
        try eq(2, utree.events.get(1).children.single);
    }

    {
        var list = try utree.setCurrentEventIndex(1);
        defer list.deinit();
        try eq(utree.current_event_index, 1);
        try eqSlice(u16, &.{2}, list.items);

        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 0, .col = 11 }, .chars = " venus" } });
        try eq(4, utree.events.len);
        try eq(1, utree.events.get(2).parent);
        try eq(1, utree.events.get(3).parent);
        try eqSlice(u16, &.{ 2, 3 }, utree.events.get(1).children.multiple.items);
    }
}

fn createEvent(self: *UndoTree, node: ?RcNode, kind: Event.Kind, changes: Event.Changes) Event {
    return Event{
        .node = node,
        .timestamp = std.time.milliTimestamp(),
        .kind = kind,
        .changes = changes,
        .children = .none,
        .parent = self.current_event_index,
    };
}

fn updateCurrentIndexAfterAppend(self: *@This()) !void {
    const new_child_index: u16 = @intCast(self.events.len - 1);
    defer self.current_event_index = new_child_index;

    const parent_children = &self.events.items(.children)[self.current_event_index];
    switch (parent_children.*) {
        .none => parent_children.* = .{ .single = new_child_index },
        .single => |single_child_index| {
            const list = try self.a.create(Event.ChildrenIndexList);
            list.* = try Event.ChildrenIndexList.initCapacity(self.a, 2);
            try list.append(single_child_index);
            try list.append(new_child_index);
            parent_children.* = .{ .multiple = list };
        },
        .multiple => try parent_children.*.multiple.append(new_child_index),
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

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
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 }, .chars = "h" } });
        try eqSlice(?u16, &.{ null, 0 }, utree.events.items(.parent));
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 2 }, .chars = "e" } });
        try eqSlice(?u16, &.{ null, 0, 1 }, utree.events.items(.parent));
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 3 }, .chars = "l" } });
        try eqSlice(?u16, &.{ null, 0, 1, 2 }, utree.events.items(.parent));
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 }, .chars = "l" } });
        try eqSlice(?u16, &.{ null, 0, 1, 2, 3 }, utree.events.items(.parent));
        try utree.addUndoEvent(null, .insert, .{ .single = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 }, .chars = "o" } });
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

//////////////////////////////////////////////////////////////////////////////////////////////

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

const EventList = std.MultiArrayList(Event);

const Event = struct {
    node: ?RcNode = null,

    timestamp: i64,

    parent: ?u16 = null,
    children: union(enum) {
        none,
        single: u16,
        multiple: *ChildrenIndexList,
    },

    changes: Changes,
    kind: Kind,

    ///////////////////////////////////////////////////////////////////////////////////////

    const ChildrenIndexList = std.ArrayList(u16);

    const Kind = enum { original, insert, delete };

    const Changes = union(enum) {
        none,
        single: Modification,
        multiple: []Modification,
    };

    const Modification = struct {
        start: CursorPoint = .{},
        end: CursorPoint = .{},
        chars: []const u8 = "",
    };
};

const CursorPoint = struct {
    line: u16 = 0,
    col: u16 = 0,
};
