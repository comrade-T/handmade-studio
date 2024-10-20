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
const CursorRange = rcr.CursorRange;
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

////////////////////////////////////////////////////////////////////////////////////////////// insertChars

pub fn insertChars(self: *@This(), chars: []const u8, destination: CursorPoint) !CursorPoint {
    const line, const col, self.root = try self.insertAndBalance(chars, destination);
    try self.pending.append(self.root);
    return .{ .line = line, .col = col };
}

test insertChars {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello");
    defer ropeman.deinit();
    try eqStr("hello", try ropeman.toString(idc_if_it_leaks, .lf));
    try eq(.{ 0, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    {
        const point = try ropeman.insertChars("//", .{ .line = 0, .col = 0 });
        try eq(CursorPoint{ .line = 0, .col = 2 }, point);
        try eqStr("//hello", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 1, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    {
        const point = try ropeman.insertChars(" ", .{ .line = 0, .col = 2 });
        try eq(CursorPoint{ .line = 0, .col = 3 }, point);
        try eqStr("// hello", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

fn insertAndBalance(self: *@This(), chars: []const u8, destination: CursorPoint) !struct { usize, usize, RcNode } {
    const line, const col, const new_root = try rcr.insertChars(self.root, self.a, &self.arena, chars, destination);
    const is_rebalanced, const balanced_root = try rcr.balance(self.a, new_root);
    if (is_rebalanced) rcr.freeRcNode(self.a, new_root);
    return .{ line, col, balanced_root };
}

////////////////////////////////////////////////////////////////////////////////////////////// insertCharsMultiCursor

pub fn insertCharsMultiCursor(self: *@This(), a: Allocator, chars: []const u8, destinations: []const CursorPoint) ![]CursorPoint {
    assert(destinations.len > 1);
    assert(std.sort.isSorted(CursorPoint, destinations, {}, CursorPoint.cmp));
    var points = try a.alloc(CursorPoint, destinations.len);
    var i = destinations.len;
    while (i > 0) {
        i -= 1;
        points[i].line, points[i].col, self.root = try self.insertAndBalance(chars, destinations[i]);
        try self.pending.append(self.root);
    }
    adjustPointsAfterMultiCursorInsert(points, chars);
    return points;
}

fn adjustPointsAfterMultiCursorInsert(points: []CursorPoint, chars: []const u8) void {
    var last_line = chars;
    var nlcount: u16 = 0;
    var split_iter = std.mem.split(u8, chars, "\n");
    while (split_iter.next()) |chunk| {
        last_line = chunk;
        nlcount += 1;
    }
    nlcount -|= 1;

    if (nlcount > 0) {
        const noc: u16 = @intCast(rcr.getNumOfChars(last_line));
        for (points, 0..) |point, i| {
            const i_u16: u16 = @intCast(i);
            points[i].line = point.line + (nlcount * i_u16);
            points[i].col = if (nlcount == 0) point.col + noc else noc;
        }
    }
}

test "insertCharsMultiCursor - with new lines - 2 points start at same line" {
    var ropeman = try RopeMan.initFromString(testing_allocator, "one two");
    defer ropeman.deinit();
    const input_points = &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 3 },
    };
    const e1_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "\n", input_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 0 },
            .{ .line = 2, .col = 0 },
        }, e1_points);
        try eqStr(
            \\
            \\one
            \\ two
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e2_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "ok ", e1_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 3 },
            .{ .line = 2, .col = 3 },
        }, e2_points);
        try eqStr(
            \\
            \\ok one
            \\ok  two
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 4, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "insertCharsMultiCursor - with new lines - 3 points start at same line" {
    var ropeman = try RopeMan.initFromString(testing_allocator, "one two three");
    defer ropeman.deinit();
    const input_points = &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 3 },
        .{ .line = 0, .col = 7 },
    };
    const e1_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "\n", input_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 0 },
            .{ .line = 2, .col = 0 },
            .{ .line = 3, .col = 0 },
        }, e1_points);
        try eqStr(
            \\
            \\one
            \\ two
            \\ three
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e2_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "ok ", e1_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 3 },
            .{ .line = 2, .col = 3 },
            .{ .line = 3, .col = 3 },
        }, e2_points);
        try eqStr(
            \\
            \\ok one
            \\ok  two
            \\ok  three
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "insertCharsMultiCursor - with new lines" {
    var ropeman = try RopeMan.initFromString(testing_allocator,
        \\hello venus
        \\hello world
        \\hello kitty
    );
    defer ropeman.deinit();
    const input_points = &.{
        .{ .line = 0, .col = 5 },
        .{ .line = 1, .col = 5 },
        .{ .line = 2, .col = 5 },
    };
    const e1_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "\n", input_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 0 },
            .{ .line = 3, .col = 0 },
            .{ .line = 5, .col = 0 },
        }, e1_points);
        try eqStr(
            \\hello
            \\ venus
            \\hello
            \\ world
            \\hello
            \\ kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e2_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "ok", e1_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 2 },
            .{ .line = 3, .col = 2 },
            .{ .line = 5, .col = 2 },
        }, e2_points);
        try eqStr(
            \\hello
            \\ok venus
            \\hello
            \\ok world
            \\hello
            \\ok kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e3_points = try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "\nfine", e2_points);
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 2, .col = 4 },
            .{ .line = 5, .col = 4 },
            .{ .line = 8, .col = 4 },
        }, e3_points);
        try eqStr(
            \\hello
            \\ok
            \\fine venus
            \\hello
            \\ok
            \\fine world
            \\hello
            \\ok
            \\fine kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 9, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

test "insertCharsMultiCursor - no new lines" {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    {
        try eqSlice(
            CursorPoint,
            &.{
                .{ .line = 0, .col = 1 },
                .{ .line = 1, .col = 1 },
                .{ .line = 2, .col = 1 },
            },
            try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "/", &.{
                .{ .line = 0, .col = 0 },
                .{ .line = 1, .col = 0 },
                .{ .line = 2, .col = 0 },
            }),
        );
        try eqStr(
            \\/hello venus
            \\/hello world
            \\/hello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    {
        try eqSlice(
            CursorPoint,
            &.{
                .{ .line = 0, .col = 3 },
                .{ .line = 1, .col = 3 },
                .{ .line = 2, .col = 3 },
            },
            try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "/ ", &.{
                .{ .line = 0, .col = 1 },
                .{ .line = 1, .col = 1 },
                .{ .line = 2, .col = 1 },
            }),
        );
        try eqStr(
            \\// hello venus
            \\// hello world
            \\// hello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    {
        try eqSlice(
            CursorPoint,
            &.{
                .{ .line = 0, .col = 17 },
                .{ .line = 1, .col = 11 },
                .{ .line = 2, .col = 6 },
            },
            try ropeman.insertCharsMultiCursor(idc_if_it_leaks, "|x|", &.{
                .{ .line = 0, .col = 14 },
                .{ .line = 1, .col = 8 },
                .{ .line = 2, .col = 3 },
            }),
        );
        try eqStr(
            \\// hello venus|x|
            \\// hello|x| world
            \\// |x|hello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 9, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

////////////////////////////////////////////////////////////////////////////////////////////// deleteRange

pub fn deleteRange(self: *@This(), start: CursorPoint, end: CursorPoint) !CursorPoint {
    assert(std.sort.isSorted(CursorPoint, &.{ start, end }, {}, CursorPoint.cmp));
    self.root = try self.deleteAndBalance(start, end);
    try self.pending.append(self.root);
    return start;
}

test deleteRange {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    {
        const point = try ropeman.deleteRange(.{ .line = 0, .col = 0 }, .{ .line = 0, .col = 6 });
        try eq(CursorPoint{ .line = 0, .col = 0 }, point);
        try eqStr("venus\nhello world\nhello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 1, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    {
        const point = try ropeman.deleteRange(.{ .line = 0, .col = 0 }, .{ .line = 1, .col = 6 });
        try eq(CursorPoint{ .line = 0, .col = 0 }, point);
        try eqStr("world\nhello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

fn deleteAndBalance(self: *@This(), start: CursorPoint, end: CursorPoint) !RcNode {
    const noc = rcr.getNocOfRange(self.root, start, end);
    const new_root = try rcr.deleteChars(self.root, self.a, start, noc);
    const is_rebalanced, const balanced_root = try rcr.balance(self.a, new_root);
    if (is_rebalanced) rcr.freeRcNode(self.a, new_root);
    return balanced_root;
}

////////////////////////////////////////////////////////////////////////////////////////////// deleteRangesMultiCursor

pub fn deleteRangesMultiCursor(self: *@This(), ranges: []const CursorRange) !void {
    assert(ranges.len > 1);
    assert(std.sort.isSorted(CursorRange, ranges, {}, CursorRange.cmp));

    var i = ranges.len;
    while (i > 0) {
        i -= 1;
        const r = ranges[i];
        const noc = rcr.getNocOfRange(self.root, r.start, r.end);
        const new_root = try rcr.deleteChars(self.root, self.a, r.start, noc);
        self.root = new_root;
        try self.pending.append(new_root);
    }
}

test deleteRangesMultiCursor {
    var ropeman = try RopeMan.initFromString(testing_allocator, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    {
        try ropeman.deleteRangesMultiCursor(&.{
            .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 } },
            .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 1 } },
            .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 2, .col = 1 } },
        });
        try eqStr("ello venus\nello world\nello kitty", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    {
        try ropeman.deleteRangesMultiCursor(&.{
            .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 5 } },
            .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 5 } },
            .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 2, .col = 5 } },
        });
        try eqStr("venus\nworld\nkitty", try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

////////////////////////////////////////////////////////////////////////////////////////////// registerLastPendingToHistory

pub fn registerLastPendingToHistory(self: *@This()) !void {
    assert(self.pending.items.len > 0);
    if (self.pending.items.len == 0) return;

    const last_pending = self.pending.pop();
    try self.history.append(last_pending);

    rcr.freeRcNodes(self.a, self.pending.items);
    self.pending.clearRetainingCapacity();
}
