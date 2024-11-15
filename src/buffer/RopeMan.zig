// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

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
pub const RcNode = rcr.RcNode;
pub const CursorRange = rcr.CursorRange;
pub const CursorPoint = rcr.CursorPoint;

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

pub const InitFrom = enum { string, file };

pub fn initFrom(a: Allocator, from: InitFrom, source: []const u8) !RopeMan {
    var ropeman = try RopeMan.init(a);
    switch (from) {
        .string => ropeman.root = try rcr.Node.fromString(ropeman.a, &ropeman.arena, source),
        .file => ropeman.root = try rcr.Node.fromFile(ropeman.a, &ropeman.arena, source),
    }
    try ropeman.history.append(ropeman.root);
    return ropeman;
}

pub fn toString(self: *const @This(), a: Allocator, eol_mode: rcr.EolMode) ![]const u8 {
    return self.root.value.toString(a, eol_mode);
}

pub fn getRange(self: *const @This(), start: CursorPoint, end: ?CursorPoint, buf: []u8) []const u8 {
    return rcr.getRange(self.root, start, end, buf);
}

pub fn getByteOffsetOfRoot(self: *const @This(), line: usize, col: usize) !usize {
    return try rcr.getByteOffsetOfPosition(self.root, line, col);
}

pub fn getByteOffsetOfPosition(node: RcNode, line: usize, col: usize) !usize {
    return try rcr.getByteOffsetOfPosition(node, line, col);
}

pub fn getNumOfLines(self: *const @This()) usize {
    return self.root.value.weights().bols;
}

pub fn getNumOfCharsInLine(self: *const @This(), line: usize) usize {
    return rcr.getNumOfCharsInLine(self.root, line);
}

pub fn getLineAlloc(self: *const @This(), a: Allocator, linenr: usize, capacity: usize) ![]const u8 {
    return rcr.getLineAlloc(a, self.root, linenr, capacity);
}

pub fn debugPrint(self: *const @This()) !void {
    const str = try rcr.debugStr(self.a, self.root);
    defer self.a.free(str);
    std.debug.print("debugStr: {s}\n", .{str});
}

////////////////////////////////////////////////////////////////////////////////////////////// insertChars

pub fn insertChars(self: *@This(), a: Allocator, chars: []const u8, destinations: []const CursorPoint) ![]CursorPoint {
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

fn insertAndBalance(self: *@This(), chars: []const u8, destination: CursorPoint) !struct { usize, usize, RcNode } {
    const line, const col, const new_root = try rcr.insertChars(self.root, self.a, &self.arena, chars, destination);

    if (LADIDA == true) {
        std.debug.print("new_root: \n", .{});
        const str = try rcr.debugStr(self.a, new_root);
        defer self.a.free(str);
        std.debug.print("{s}\n", .{str});
    }

    const is_rebalanced, const balanced_root = try rcr.balance(self.a, new_root);
    if (is_rebalanced) rcr.freeRcNode(self.a, new_root);

    if (LADIDA == true and is_rebalanced) {
        std.debug.print("----x-x-x-----xx-x-x-x---xx-x-----\n", .{});
        std.debug.print("balanced_root: \n", .{});
        const str = try rcr.debugStr(self.a, balanced_root);
        defer self.a.free(str);
        std.debug.print("{s}\n", .{str});
    }

    return .{ line, col, balanced_root };
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
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one two");
    defer ropeman.deinit();
    const input_points = &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 3 },
    };
    const e1_points = try ropeman.insertChars(idc_if_it_leaks, "\n", input_points);
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
    const e2_points = try ropeman.insertChars(idc_if_it_leaks, "ok ", e1_points);
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
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one two three");
    defer ropeman.deinit();
    const input_points = &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 3 },
        .{ .line = 0, .col = 7 },
    };
    const e1_points = try ropeman.insertChars(idc_if_it_leaks, "\n", input_points);
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
    const e2_points = try ropeman.insertChars(idc_if_it_leaks, "ok ", e1_points);
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
    var ropeman = try RopeMan.initFrom(testing_allocator, .string,
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
    const e1_points = try ropeman.insertChars(idc_if_it_leaks, "\n", input_points);
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
    const e2_points = try ropeman.insertChars(idc_if_it_leaks, "ok", e1_points);
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
    const e3_points = try ropeman.insertChars(idc_if_it_leaks, "\nfine", e2_points);
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
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    {
        try eqSlice(
            CursorPoint,
            &.{
                .{ .line = 0, .col = 1 },
                .{ .line = 1, .col = 1 },
                .{ .line = 2, .col = 1 },
            },
            try ropeman.insertChars(idc_if_it_leaks, "/", &.{
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
            try ropeman.insertChars(idc_if_it_leaks, "/ ", &.{
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
            try ropeman.insertChars(idc_if_it_leaks, "|x|", &.{
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

/////////////////////////////

var LADIDA = false;

test "insertChars - single char at beginning of file multiple times" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .file, "src/window/fixtures/dummy_3_lines.zig");
    defer ropeman.deinit();

    try eqStr(
        \\const a = 10;
        \\var not_false = true;
        \\const Allocator = std.mem.Allocator;
        \\
    , try ropeman.toString(idc_if_it_leaks, .lf));

    for (0..69) |i| {
        const points = try ropeman.insertChars(testing_allocator, "a", &.{.{ .line = 0, .col = 0 }});
        defer testing_allocator.free(points);
        if (i % 20 == 0) try ropeman.registerLastPendingToHistory();
    }
    try ropeman.registerLastPendingToHistory();

    try eqStr(
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaconst a = 10;
        \\var not_false = true;
        \\const Allocator = std.mem.Allocator;
        \\
    , try ropeman.toString(idc_if_it_leaks, .lf));

    try eqStr("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaconst a = 10;", try ropeman.getLineAlloc(idc_if_it_leaks, 0, 1024));
}

test "insertChars - 'integer cast truncated bits'" {
    { // clean example, but why is it clean?
        var ropeman = try RopeMan.initFrom(testing_allocator, .file, "src/window/fixtures/dummy_3_lines.zig");
        defer ropeman.deinit();

        for (0..69) |i| {
            const chars = try std.fmt.allocPrint(testing_allocator, "{c}", .{@as(u8, @intCast(i + 49))});
            defer testing_allocator.free(chars);
            const points = try ropeman.insertChars(testing_allocator, chars, &.{.{ .line = 0, .col = i }});
            defer testing_allocator.free(points);
            try ropeman.registerLastPendingToHistory();
        }

        try eqStr("123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuconst a = 10;", try ropeman.getLineAlloc(idc_if_it_leaks, 0, 1024));
    }
    { // guilty example

        // if I don't call rcr.balance() in insertAndBalance(), and return only the result from insertChars(),
        // this example won't panic.

        // I tried to `self.pending.append(new_root)` if it's rebalanced, but the error still occurs.

        var ropeman = try RopeMan.initFrom(testing_allocator, .file, "src/window/fixtures/dummy_3_lines.zig");
        defer ropeman.deinit();

        LADIDA = true;
        defer LADIDA = false;

        for (0..69) |i| {
            std.debug.print("\ni = {d} ===================================================================\n\n", .{i});

            const chars = try std.fmt.allocPrint(testing_allocator, "{c}", .{@as(u8, @intCast(i + 49))});
            defer testing_allocator.free(chars);
            const points = try ropeman.insertChars(testing_allocator, chars, &.{.{ .line = 0, .col = i }});
            defer testing_allocator.free(points);
            if (i % 4 == 0) {
                std.debug.print("\n------ YO I' FREEING THIS SHIT : pending_len: {d} ~~~~~~~~~~~~~~~~~~~~~`\n\n", .{ropeman.pending.items.len});
                try ropeman.registerLastPendingToHistory();
                std.debug.print("root after free:  \n", .{});
                try ropeman.debugPrint();
            }
        }
        try ropeman.registerLastPendingToHistory();

        try eqStr("123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuconst a = 10;", try ropeman.getLineAlloc(idc_if_it_leaks, 0, 1024));
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// deleteRanges

pub fn deleteRanges(self: *@This(), a: Allocator, ranges: []const CursorRange) ![]CursorPoint {
    assert(std.sort.isSorted(CursorRange, ranges, {}, CursorRange.cmp));
    var i = ranges.len;
    while (i > 0) {
        i -= 1;
        self.root = try self.deleteAndBalance(ranges[i]);
        try self.pending.append(self.root);
    }
    return try adjustPointsAfterMultiCursorDelete(a, ranges);
}

fn deleteAndBalance(self: *@This(), r: CursorRange) !RcNode {
    if (r.isEmpty()) return self.root.retain();
    const noc = rcr.getNocOfRange(self.root, r.start, r.end);
    const new_root = try rcr.deleteChars(self.root, self.a, r.start, noc);
    const is_rebalanced, const balanced_root = try rcr.balance(self.a, new_root);
    if (is_rebalanced) rcr.freeRcNode(self.a, new_root);
    return balanced_root;
}

fn adjustPointsAfterMultiCursorDelete(a: Allocator, ranges: []const CursorRange) ![]CursorPoint {
    var points = try a.alloc(CursorPoint, ranges.len);

    var total_deficit: usize = 0;
    var subject: usize = 0;
    var debt: usize = 0;
    var anchor: usize = 0;

    for (ranges, 0..) |r, i| {
        const deficit = r.end.line - r.start.line;
        defer total_deficit += deficit;

        const adjusted_start_line = r.start.line - total_deficit;
        if (adjusted_start_line > subject) {
            subject = adjusted_start_line;
            debt = 0;
            anchor = 0;
        }

        const p = CursorPoint{
            .line = adjusted_start_line,
            .col = r.start.col + anchor - debt,
        };
        defer points[i] = p;

        if (deficit == 0) {
            debt += r.end.col - r.start.col;
            continue;
        }

        anchor = p.col + debt;
    }

    return points;
}

test "deleteRangesMultiCursor - single line - case 1a - delete 3 spaces in 'one two three four'" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one two three four");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 3 }, .end = .{ .line = 0, .col = 4 } },
        .{ .start = .{ .line = 0, .col = 7 }, .end = .{ .line = 0, .col = 8 } },
        .{ .start = .{ .line = 0, .col = 13 }, .end = .{ .line = 0, .col = 14 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 3 },
            .{ .line = 0, .col = 6 },
            .{ .line = 0, .col = 11 },
        }, e1_points);
        try eqStr(
            \\onetwothreefour
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}
test "deleteRangesMultiCursor - single line - case 1b - delete 3 spaces in 'one two three four'" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\none two three four");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 1, .col = 3 }, .end = .{ .line = 1, .col = 4 } },
        .{ .start = .{ .line = 1, .col = 7 }, .end = .{ .line = 1, .col = 8 } },
        .{ .start = .{ .line = 1, .col = 13 }, .end = .{ .line = 1, .col = 14 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 1, .col = 3 },
            .{ .line = 1, .col = 6 },
            .{ .line = 1, .col = 11 },
        }, e1_points);
        try eqStr(
            \\hello world
            \\onetwothreefour
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}
test "deleteRangesMultiCursor - single line - case 2 - delete 'one ' & 'three '" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one two three four");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 } },
        .{ .start = .{ .line = 0, .col = 8 }, .end = .{ .line = 0, .col = 14 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 0, .col = 4 },
        }, e1_points);
        try eqStr(
            \\two four
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "deleteRangesMultiCursor - with line shifts - distant affected" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "venus venue\nhello world\nhello kitty");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 1, .col = 6 } },
        .{ .start = .{ .line = 2, .col = 4 }, .end = .{ .line = 2, .col = 6 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 5 },
            .{ .line = 1, .col = 4 },
        }, e1_points);
        try eqStr(
            \\venusworld
            \\hellkitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 2, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "deleteRangesMultiCursor - with line shifts - 1st case" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 0 } },
        .{ .start = .{ .line = 0, .col = 11 }, .end = .{ .line = 1, .col = 0 } },
        .{ .start = .{ .line = 1, .col = 11 }, .end = .{ .line = 2, .col = 0 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 0, .col = 11 },
            .{ .line = 0, .col = 22 },
        }, e1_points);
        try eqStr(
            \\hello venushello worldhello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e2_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 0 } },
        .{ .start = .{ .line = 0, .col = 10 }, .end = .{ .line = 0, .col = 11 } },
        .{ .start = .{ .line = 0, .col = 21 }, .end = .{ .line = 0, .col = 22 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 0, .col = 10 },
            .{ .line = 0, .col = 20 },
        }, e2_points);
        try eqStr(
            \\hello venuhello worlhello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e3_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 0 } },
        .{ .start = .{ .line = 0, .col = 9 }, .end = .{ .line = 0, .col = 10 } },
        .{ .start = .{ .line = 0, .col = 19 }, .end = .{ .line = 0, .col = 20 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 0, .col = 9 },
            .{ .line = 0, .col = 18 },
        }, e3_points);
        try eqStr(
            \\hello venhello worhello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 9, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "deleteRangesMultiCursor - with line shifts - 2nd case" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 0, .col = 6 } },
        .{ .start = .{ .line = 0, .col = 11 }, .end = .{ .line = 1, .col = 0 } },
        .{ .start = .{ .line = 1, .col = 11 }, .end = .{ .line = 2, .col = 0 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 5 },
            .{ .line = 0, .col = 10 },
            .{ .line = 0, .col = 21 },
        }, e1_points);
        try eqStr(
            \\hellovenushello worldhello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "deleteRangesMultiCursor - with line shifts - 3rd case" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 0 } },
        .{ .start = .{ .line = 0, .col = 5 }, .end = .{ .line = 0, .col = 6 } },
        .{ .start = .{ .line = 0, .col = 11 }, .end = .{ .line = 1, .col = 0 } },
        .{ .start = .{ .line = 1, .col = 5 }, .end = .{ .line = 1, .col = 6 } },
        .{ .start = .{ .line = 1, .col = 11 }, .end = .{ .line = 2, .col = 0 } },
        .{ .start = .{ .line = 2, .col = 5 }, .end = .{ .line = 2, .col = 6 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 0, .col = 5 },
            .{ .line = 0, .col = 10 },
            .{ .line = 0, .col = 15 },
            .{ .line = 0, .col = 20 },
            .{ .line = 0, .col = 25 },
        }, e1_points);
        try eqStr(
            \\hellovenushelloworldhellokitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
}

test "deleteRangesMultiCursor - multiple lines - no line shifts" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello venus\nhello world\nhello kitty");
    defer ropeman.deinit();
    const e1_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 } },
        .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 1 } },
        .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 2, .col = 1 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 0 },
            .{ .line = 1, .col = 0 },
            .{ .line = 2, .col = 0 },
        }, e1_points);
        try eqStr(
            \\ello venus
            \\ello world
            \\ello kitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 3, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    const e2_points = try ropeman.deleteRanges(idc_if_it_leaks, &.{
        .{ .start = .{ .line = 0, .col = 1 }, .end = .{ .line = 0, .col = 5 } },
        .{ .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 5 } },
        .{ .start = .{ .line = 2, .col = 1 }, .end = .{ .line = 2, .col = 5 } },
    });
    {
        try eqSlice(CursorPoint, &.{
            .{ .line = 0, .col = 1 },
            .{ .line = 1, .col = 1 },
            .{ .line = 2, .col = 1 },
        }, e2_points);
        try eqStr(
            \\evenus
            \\eworld
            \\ekitty
        , try ropeman.toString(idc_if_it_leaks, .lf));
        try eq(.{ 6, 1 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
    }
    try ropeman.registerLastPendingToHistory();
    try eq(.{ 0, 2 }, .{ ropeman.pending.items.len, ropeman.history.items.len });
}

////////////////////////////////////////////////////////////////////////////////////////////// registerLastPendingToHistory

pub fn registerLastPendingToHistory(self: *@This()) !void {
    if (self.pending.items.len == 0) return;

    const last_pending = self.pending.pop();
    try self.history.append(last_pending);

    rcr.freeRcNodes(self.a, self.pending.items);
    self.pending.clearRetainingCapacity();
}
