const RopeMan = @This();
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

const rcr = @import("RcRope.zig");
const RcNode = rcr.RcNode;
const CursorPoint = rcr.CursorPoint;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
arena: ArenaAllocator,

root: RcNode = undefined,
pending: ArrayList(RcNode),
history: ArrayList(RcNode),

fn init(a: Allocator) !RopeMan {
    return RopeMan{
        .a = a,
        .arena = ArenaAllocator.init(a),
        .pending = ArrayList(RcNode).init(a),
        .history = ArrayList(RcNode).init(a),
    };
}

pub fn deinit(self: *@This()) void {
    rcr.freeRcNodes(self.a, self.pending.items);
    self.pending.deinit();
    rcr.freeRcNodes(self.a, self.history.items);
    self.history.deinit();
    self.arena.deinit();
}

pub fn initFromString(a: Allocator, source: []const u8) !RopeMan {
    var ropeman = try RopeMan.init(a);
    ropeman.root = try rcr.Node.fromString(ropeman.a, &ropeman.arena, source);
    try ropeman.history.append(ropeman.root);
    return ropeman;
}

pub fn toString(self: *@This(), a: Allocator, eol_mode: rcr.EolMode) ![]const u8 {
    return self.root.value.toString(a, eol_mode);
}

///////////////////////////// insertChars

pub fn insertChars(self: *@This(), chars: []const u8, destination: CursorPoint) !CursorPoint {
    const line, const col, const new_root = try rcr.insertChars(self.root, self.a, &self.arena, chars, destination);
    self.root = new_root;
    try self.pending.append(new_root);
    return .{ .line = line, .col = col };
}

test insertChars {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello");
    defer ropeman.deinit();

    try eqStr("hello", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 0, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });

    const e1p = try ropeman.insertChars("//", .{ .line = 0, .col = 0 });
    try eq(CursorPoint{ .line = 0, .col = 2 }, e1p);
    try eqStr("//hello", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 1, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });

    const e2p = try ropeman.insertChars(" ", e1p);
    try eq(CursorPoint{ .line = 0, .col = 3 }, e2p);
    try eqStr("// hello", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });

    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

///////////////////////////// insertCharsMultiCursor

pub fn insertCharsMultiCursor(self: *@This(), chars: []const u8, destinations: []const CursorPoint) !void {
    assert(destinations.len > 1);
    assert(std.sort.isSorted(CursorPoint, destinations, {}, CursorPoint.cmp));

    var i = destinations.len;
    while (i > 0) {
        i -= 1;
        const d = destinations[i];
        _, _, const new_root = try rcr.insertChars(self.root, self.a, &self.arena, chars, d);
        self.root = new_root;
        try self.pending.append(new_root);
    }
}

test insertCharsMultiCursor {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();

    try ropeman.insertCharsMultiCursor("/", &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 1, .col = 0 },
        .{ .line = 2, .col = 0 },
    });
    try eqStr("/hello venus\n/hello world\n/hello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
}

///////////////////////////// deleteRange

pub fn deleteRange(self: *@This(), start: CursorPoint, end: CursorPoint) !void {
    const noc = rcr.getNocOfRange(self.root, start, end);
    const new_root = try rcr.deleteChars(self.root, self.a, start, noc);
    self.root = new_root;
    try self.pending.append(new_root);
}

test deleteRange {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();

    try ropeman.deleteRange(.{ .line = 0, .col = 0 }, .{ .line = 0, .col = 6 });
    try eqStr("venus\nhello world\nhello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 1, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });

    try ropeman.deleteRange(.{ .line = 0, .col = 0 }, .{ .line = 1, .col = 6 });
    try eqStr("world\nhello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });

    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

///////////////////////////// registerLastPendingToHistory

fn registerLastPendingToHistory(self: *@This()) !void {
    assert(self.pending.items.len > 0);
    if (self.pending.items.len == 0) return;

    const last_pending = self.pending.pop();
    try self.history.append(last_pending);

    rcr.freeRcNodes(self.a, self.pending.items);
    self.pending.clearRetainingCapacity();
}
