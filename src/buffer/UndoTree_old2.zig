const UndoTree = @This();

const rcr = @import("RcRope.zig");
const RcNode = rcr.RcNode;
const Node = rcr.Node;
const freeRcNode = rcr.freeRcNode;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const EventList = std.MultiArrayList(Event);

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
arena: ArenaAllocator,

events: EventList,

active_event_index: u16,

fn init(a: Allocator, opts: InitOption) !UndoTree {
    var events = EventList{};
    switch (opts) {
        .new => |node| {
            try events.append(a, Event{
                .node = node,
                .parent = null,
                .timestamp = std.time.milliTimestamp(),
                .kind = .none,
                .children = .none,
                .changes = .none,
            });
        },
        .load => unreachable,
    }
    return UndoTree{
        .a = a,
        .arena = ArenaAllocator.init(a),
        .active_event_index = 0,
        .events = events,
    };
}

const InitOption = union(enum) {
    new: RcNode,
    load: void,
};

fn deinit(self: *@This()) void {
    self.events.deinit(self.a);
    self.arena.deinit();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn finalizeUniformedInsertEvent(self: *@This(), node: RcNode, builder: UniformedInsertEventBuilder) !Event {
    const ranges = try builder.calculateFinalRanges(self.arena.allocator());
    const event = Event{
        .node = node,
        .parent = self.active_event_index,
        .timestamp = std.time.milliTimestamp(),
        .kind = .insert,
        .children = .none,
        .changes = Event.Changes{ .multiple_uniformed = .{
            .ranges = ranges,
            .contents = builder.contents,
        } },
    };
    builder.deinit();
    return event;
}

test finalizeUniformedInsertEvent {
    const source =
        \\const one = 1;
        \\const two = 2;
        \\var x: u32 = one + two;
        \\const not_false = true;
    ;

    var arena = ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const root = try Node.fromString(testing_allocator, &arena, source);
    defer freeRcNode(root);

    var utree = try UndoTree.init(testing_allocator, .{ .new = root });
    defer utree.deinit();

    var builder = try UniformedInsertEventBuilder.init(testing_allocator);
    defer builder.deinit();

    /////////////////////////////

    try builder.addInitialPoint(.{ .line = 0, .col = 0 });
    try builder.addInitialPoint(.{ .line = 1, .col = 0 });
    try builder.addInitialPoint(.{ .line = 3, .col = 0 });

    // TODO: push pending nodes to builder, so builder can free everything exept the last node

    // const b1e1L, const b1e1C, const b1e1 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = 0, .col = 0 });
    // const b1e2L, const b1e2C, const b1e2 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = 1, .col = 0 });
    // const b1e3L, const b1e3C, const b1e3 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = 3, .col = 0 });
    // try builder.appendChars("/");
    //
    // const b2e1L, const b2e1C, const b2e1 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = b1e1L, .col = b1e1C });
    // const b2e2L, const b2e2C, const b2e2 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = b1e2L, .col = b1e2C });
    // const b2e3L, const b2e3C, const b2e3 = try Node.insertChars(root, testing_allocator, &arena, "/", .{ .line = b1e3L, .col = b1e3C });
    // try builder.appendChars("/");
    //
    // const b3e1L, const b3e1C, const b3e1 = try Node.insertChars(root, testing_allocator, &arena, " ", .{ .line = b2e1L, .col = b2e1C });
    // const b3e2L, const b3e2C, const b3e2 = try Node.insertChars(root, testing_allocator, &arena, " ", .{ .line = b2e2L, .col = b2e2C });
    // const b3e3L, const b3e3C, const b3e3 = try Node.insertChars(root, testing_allocator, &arena, " ", .{ .line = b2e3L, .col = b2e3C });
    // try builder.appendChars(" ");
}

//////////////////////////////////////////////////////////////////////////////////////////////

const UniformedInsertEventBuilder = struct {
    a: Allocator,
    points: ArrayList(CursorPoint),
    contents: []const u8 = "",

    fn init(a: Allocator) !UniformedInsertEventBuilder {
        return UniformedInsertEventBuilder{ .a = a, .points = ArrayList(CursorPoint).init(a) };
    }

    fn deinit(self: *@This()) void {
        self.points.deinit();
        self.a.free(self.contents);
    }

    fn addInitialPoint(self: *@This(), point: CursorPoint) !void {
        try self.points.append(point);
    }

    fn appendChars(self: *@This(), new_chars: []const u8) !void {
        const old_contents = self.contents;
        defer if (self.contents.len > 0) self.a.free(old_contents);
        self.contents = try std.fmt.allocPrint(self.a, "{s}{s}", .{ self.contents, new_chars });
    }

    fn calculateFinalRanges(self: *@This(), a: Allocator) ![]CursorRange {
        var list = try ArrayList(CursorRange).initCapacity(a, self.points.items.len);
        var last_line = self.contents;
        var nlcount: u16 = 0;

        var iter = std.mem.split(u8, self.contents, "\n");
        while (iter.next()) |chunk| {
            last_line = chunk;
            nlcount += 1;
        }
        nlcount -|= 1;

        const noc: u16 = @intCast(rcr.getNumOfChars(last_line));

        for (self.points.items, 0..) |point, i_| {
            const i: u16 = @intCast(i_);
            const start_line = point.line + (nlcount * i);
            const end_line = point.line + (nlcount * (i + 1));
            const end_col = if (nlcount == 0) point.col + noc else noc;
            try list.append(CursorRange{
                .start = CursorPoint{ .line = start_line, .col = point.col },
                .end = CursorPoint{ .line = end_line, .col = end_col },
            });
        }

        return try list.toOwnedSlice();
    }
};

test UniformedInsertEventBuilder {
    var builder = try UniformedInsertEventBuilder.init(testing_allocator);
    defer builder.deinit();

    try builder.addInitialPoint(.{ .line = 0, .col = 0 });
    try builder.addInitialPoint(.{ .line = 1, .col = 0 });
    try builder.addInitialPoint(.{ .line = 3, .col = 5 });
    try builder.addInitialPoint(.{ .line = 5, .col = 10 });
    try eq(4, builder.points.items.len);

    ///////////////////////////// no line shifts

    try builder.appendChars("h");
    try builder.appendChars("i");
    try eqStr("hi", builder.contents);
    try eqSlice(CursorRange, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 2 } },
        .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 2 } },
        .{ .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 7 } },
        .{ .start = .{ .line = 5, .col = 10 }, .end = .{ .line = 5, .col = 12 } },
    }, try builder.calculateFinalRanges(idc_if_it_leaks));

    ///////////////////////////// 1st round of line shifts

    try builder.appendChars("\n");
    try eqStr("hi\n", builder.contents);
    try eqSlice(CursorRange, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 1, .col = 0 } },
        .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 3, .col = 0 } },
        .{ .start = .{ .line = 5, .col = 5 }, .end = .{ .line = 6, .col = 0 } },
        .{ .start = .{ .line = 8, .col = 10 }, .end = .{ .line = 9, .col = 0 } },
    }, try builder.calculateFinalRanges(idc_if_it_leaks));

    ///////////////////////////// 2nd round of line shifts

    try builder.appendChars("\n");
    try eqStr("hi\n\n", builder.contents);
    try eqSlice(CursorRange, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 2, .col = 0 } },
        .{ .start = .{ .line = 3, .col = 0 }, .end = .{ .line = 5, .col = 0 } },
        .{ .start = .{ .line = 7, .col = 5 }, .end = .{ .line = 9, .col = 0 } },
        .{ .start = .{ .line = 11, .col = 10 }, .end = .{ .line = 13, .col = 0 } },
    }, try builder.calculateFinalRanges(idc_if_it_leaks));

    ///////////////////////////// no line shifts

    try builder.appendChars("hello");
    try eqStr("hi\n\nhello", builder.contents);
    try eqSlice(CursorRange, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 2, .col = 5 } },
        .{ .start = .{ .line = 3, .col = 0 }, .end = .{ .line = 5, .col = 5 } },
        .{ .start = .{ .line = 7, .col = 5 }, .end = .{ .line = 9, .col = 5 } },
        .{ .start = .{ .line = 11, .col = 10 }, .end = .{ .line = 13, .col = 5 } },
    }, try builder.calculateFinalRanges(idc_if_it_leaks));
}

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

    const Kind = enum { none, insert, delete };

    const Children = union(enum) {
        none,
        single: u16,
        multiple: *ArrayList(u16),
    };

    const Changes = union(enum) {
        none,
        single: Single,
        multiple_distinct: []Single,
        multiple_uniformed: Uniformed,

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
    try eq(.{ 8, 88 }, .{ @alignOf(Event), @sizeOf(Event) }); // 1000 events -> ~100kb in memory
}
