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

const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const code_point = @import("code_point");
const RopeMan = @import("RopeMan");
const SeekCallback = RopeMan.SeekCallback;

pub const Limit = struct {
    start_line: u32 = 0,
    end_line: u32 = std.math.maxInt(u32),
};

////////////////////////////////////////////////////////////////////////////////////////////// CursorManager

a: Allocator,

cursor_mode: CursorMode = .point,
uniform_mode: UniformMode = .uniformed,

main_cursor_id: usize = 0,
cursor_id_count: usize = 0,
cursors: CursorMap,

just_moved: bool = false,

limit: Limit = .{},

pub fn create(a: Allocator) !*CursorManager {
    var self = try a.create(@This());
    self.* = .{
        .a = a,
        .cursors = CursorMap.init(self.a),
    };
    try self.addPointCursor(0, 0, true);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.cursors.deinit();
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Producing Points & Ranges

/// Allocate & set `RopeMan.CursorPoint` slice from cursors.
/// Temporary solution to avoid circular references between `CursorManager` & `RopeMan` modules.
/// Would love to have a solution where I don't have to allocate memory.
pub fn produceCursorPoints(self: *@This(), a: Allocator) ![]RopeMan.CursorPoint {
    assert(self.cursor_mode == .point);
    var points = try a.alloc(RopeMan.CursorPoint, self.cursors.values().len);
    for (self.cursors.values(), 0..) |*cursor, i| {
        points[i] = .{ .line = cursor.start.line, .col = cursor.start.col };
    }
    return points;
}

/// Allocate & set `RopeMan.CursorRange` slice from cursors.
/// Temporary solution to avoid circular references between `CursorManager` & `RopeMan` modules.
/// Would love to have a solution where I don't have to allocate memory.
pub fn produceCursorRanges(self: *@This(), a: Allocator) ![]RopeMan.CursorRange {
    assert(self.cursor_mode == .range);
    var ranges = try a.alloc(RopeMan.CursorRange, self.cursors.values().len);
    for (self.cursors.values(), 0..) |*cursor, i| {
        ranges[i] = .{
            .start = .{ .line = cursor.start.line, .col = cursor.start.col },
            .end = .{ .line = cursor.end.line, .col = cursor.end.col + 1 },
        };
    }
    return ranges;
}

pub fn produceBackspaceRanges(self: *@This(), a: Allocator, ropeman: *const RopeMan) ![]RopeMan.CursorRange {
    var ranges = try a.alloc(RopeMan.CursorRange, self.cursors.values().len);
    for (self.cursors.values(), 0..) |*cursor, i| {
        if (cursor.start.line == 0 and cursor.start.col == 0) {
            ranges[i] = .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 0 } };
            continue;
        }

        if (cursor.start.col == 0) {
            const prev_linenr = cursor.start.line - 1;
            const prev_line_noc = ropeman.getNumOfCharsInLine(prev_linenr);
            ranges[i] = .{
                .start = .{ .line = cursor.start.line - 1, .col = prev_line_noc },
                .end = .{ .line = cursor.start.line, .col = 0 },
            };
            continue;
        }

        assert(cursor.start.col > 0);
        ranges[i] = .{
            .start = .{ .line = cursor.start.line, .col = cursor.start.col - 1 },
            .end = .{ .line = cursor.start.line, .col = cursor.start.col },
        };
    }
    return ranges;
}

///////////////////////////// Text Objects

pub fn produceInWordRanges(self: *@This(), a: Allocator, ropeman: *const RopeMan, boundary_kind: Anchor.WordTextObjectCtx.WordBoundaryKind) ![]RopeMan.CursorRange {
    assert(self.cursor_mode == .point);
    var ranges = try a.alloc(RopeMan.CursorRange, self.cursors.values().len);
    for (self.cursors.values(), 0..) |*cursor, i| {
        if (cursor.start.getInWordTextObject(ropeman, boundary_kind)) |range| {
            ranges[i] = range;
            continue;
        }
        ranges[i] = .{
            .start = .{ .line = cursor.start.line, .col = cursor.start.col },
            .end = .{ .line = cursor.start.line, .col = cursor.start.col },
        };
    }
    return ranges;
}

pub fn produceInSingleQuoteRanges(self: *@This(), a: Allocator, ropeman: *const RopeMan) ![]RopeMan.CursorRange {
    assert(self.cursor_mode == .point);
    var ranges = try a.alloc(RopeMan.CursorRange, self.cursors.values().len);
    for (self.cursors.values(), 0..) |*cursor, i| {
        if (cursor.start.getSingleQuoteTextObject(ropeman)) |range| {
            ranges[i] = range;
            ranges[i].start.col += 1;
            continue;
        }
        ranges[i] = .{
            .start = .{ .line = cursor.start.line, .col = cursor.start.col },
            .end = .{ .line = cursor.start.line, .col = cursor.start.col },
        };
    }
    return ranges;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn mainCursor(self: *@This()) *Cursor {
    return self.cursors.getPtr(self.main_cursor_id) orelse @panic("Unable to get main cursor");
}

///////////////////////////// Set Limit

pub fn setLimit(self: *@This(), start_line: u32, end_line: u32) void {
    self.limit = Limit{ .start_line = start_line, .end_line = end_line };
}

///////////////////////////// Mode Activations

pub fn setJustMovedToFalse(self: *@This()) void {
    assert(self.just_moved == true);
    self.just_moved = false;
}

pub fn activateSingleMode(self: *@This()) void {
    assert(self.uniform_mode == .uniformed);
    self.uniform_mode = .single;
}

pub fn activateUniformedMode(self: *@This()) void {
    assert(self.uniform_mode == .single);
    self.uniform_mode = .uniformed;
}

pub fn activatePointMode(self: *@This()) void {
    assert(self.cursor_mode == .range);
    self.cursor_mode = .point;
    for (self.cursors.values()) |*cursor| cursor.current_anchor = .start;
}

pub fn activateRangeMode(self: *@This()) void {
    assert(self.cursor_mode == .point);
    self.cursor_mode = .range;
    for (self.cursors.values()) |*cursor| {
        cursor.current_anchor = .end;
        cursor.end.line = cursor.start.line;
        cursor.end.col = cursor.start.col;
    }
}

test activateRangeMode {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars");
    defer ropeman.deinit();

    var cm = try CursorManager.create(testing_allocator);
    defer cm.destroy();

    cm.activateRangeMode();
    try eqCursor(.{ 0, 0, 0, 0 }, cm.mainCursor().*);

    cm.moveRight(1, &ropeman);
    try eqCursor(.{ 0, 0, 0, 1 }, cm.mainCursor().*);

    cm.moveDown(1, &ropeman);
    try eqCursor(.{ 0, 0, 1, 1 }, cm.mainCursor().*);
}

///////////////////////////// Setting / Adding Cursors

pub fn setActiveCursor(self: *@This(), cursor_id: usize) void {
    assert(self.cursors.contains(cursor_id));
    if (!self.cursors.contains(cursor_id)) return;
    self.main_cursor_id = cursor_id;
}

pub fn addPointCursor(self: *@This(), line: usize, col: usize, make_main: bool) !void {
    assert(self.cursor_mode == .point);
    const new_cursor = Cursor{
        .start = Anchor{ .line = line, .col = col },
        .end = Anchor{ .line = line, .col = col + 1 },
    };

    const existing_index = std.sort.binarySearch(
        Cursor,
        self.cursors.values(),
        new_cursor,
        CursorMapContext.order,
    );
    if (existing_index != null) return;

    try self.addNewCursorThenSortAllCursors(new_cursor, make_main);
}

fn addNewCursorThenSortAllCursors(self: *@This(), new_cursor: Cursor, make_main: bool) !void {
    defer self.cursor_id_count += 1;
    try self.cursors.put(self.cursor_id_count, new_cursor);
    if (make_main) self.main_cursor_id = self.cursor_id_count;
    self.cursors.sort(CursorMapContext{ .cursors = self.cursors.values() });
}

test addPointCursor {
    {
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // initital cursor position is line=0 col=0 on CursorManager.create()
        try eq(1, cm.cursors.values().len);
        try eq(Anchor{ .line = 0, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);

        // add 2nd cursor AFTER the initial cursor
        try cm.addPointCursor(0, 5, true);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.getPtr(0).?.activeAnchor(cm).*);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.getPtr(1).?.activeAnchor(cm).*);
    }
    {
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // update the initial cursor
        cm.mainCursor().setActiveAnchor(cm, 0, 5);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        // add 2nd cursor BEFORE the initial cursor
        try cm.addPointCursor(0, 0, true);
        try eq(Anchor{ .line = 0, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);
        // make sure the cursors are sorted
        try eqSlice(usize, &.{ 1, 0 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].activeAnchor(cm).*);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[1].activeAnchor(cm).*);
    }
    { // cursor position already exist
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();
        try eqSlice(usize, &.{0}, cm.cursors.keys());

        try cm.addPointCursor(0, 0, true);
        try eqSlice(usize, &.{0}, cm.cursors.keys());

        try cm.addPointCursor(0, 5, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());

        try cm.addPointCursor(0, 0, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try cm.addPointCursor(0, 5, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Selection

pub fn addRangeCursor(self: *@This(), start: struct { usize, usize }, end: struct { usize, usize }, make_main: bool) !void {
    assert(self.cursor_mode == .range);
    const new_cursor = Cursor{
        .start = Anchor{ .line = start[0], .col = start[1] },
        .end = Anchor{ .line = end[0], .col = end[1] },
        .current_anchor = .end,
    };
    try self.addNewCursorThenSortAllCursors(new_cursor, make_main);
    self.mergeCursorsIfOverlap();
}

test addRangeCursor {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars");
    defer ropeman.deinit();

    { // 2x .range cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        cm.activateRangeMode();
        try eqCursor(.{ 0, 0, 0, 0 }, cm.mainCursor().*);

        // addRange
        try cm.addRangeCursor(.{ 1, 0 }, .{ 1, 0 }, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eqCursor(.{ 0, 0, 0, 0 }, cm.cursors.values()[0]);
        try eqCursor(.{ 1, 0, 1, 0 }, cm.cursors.values()[1]);

        // moveRight
        cm.moveRight(1, &ropeman);
        try eqCursor(.{ 0, 0, 0, 1 }, cm.cursors.values()[0]);
        try eqCursor(.{ 1, 0, 1, 1 }, cm.cursors.values()[1]);

        // moveDown, id=0 overlaps with id=1 -> gets merged together
        cm.moveDown(1, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eqCursor(.{ 0, 0, 2, 1 }, cm.cursors.values()[0]);
    }
}

fn eqCursor(expected: struct { usize, usize, usize, usize }, cursor: Cursor) !void {
    try eq(.{ expected[0], expected[1] }, .{ cursor.start.line, cursor.start.col });
    try eq(.{ expected[2], expected[3] }, .{ cursor.end.line, cursor.end.col });
}

////////////////////////////////////////////////////////////////////////////////////////////// Movement

pub fn moveToBeginningOfLine(self: *@This(), ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(1, ropeman, Anchor.moveToBeginningOfLine, self.limit);
}

pub fn moveToEndOfLine(self: *@This(), ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(1, ropeman, Anchor.moveToEndOfLine, self.limit);
}

pub fn moveToFirstNonSpaceCharacterOfLine(self: *@This(), ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(1, ropeman, Anchor.moveToFirstNonSpaceCharacterOfLine, self.limit);
}

/////////////////////////////

pub fn enterAFTERInsertMode(self: *@This(), ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(1, ropeman, Anchor.moveRightForAFTERInsertMode, self.limit);
}

/////////////////////////////

pub fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(by, ropeman, Anchor.moveUp, self.limit);
}

pub fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(by, ropeman, Anchor.moveDown, self.limit);
}

pub fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(by, ropeman, Anchor.moveRight, self.limit);
}

pub fn moveLeft(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithHJKLCallback(by, ropeman, Anchor.moveLeft, self.limit);
}

pub fn forwardWord(self: *@This(), start_or_end: Anchor.StartOrEnd, boundary_kind: Anchor.BoundaryKind, count: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithVimCallback(self.a, count, start_or_end, boundary_kind, ropeman, Anchor.forwardWord, self.limit);
}

pub fn backwardsWord(self: *@This(), start_or_end: Anchor.StartOrEnd, boundary_kind: Anchor.BoundaryKind, count: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithVimCallback(self.a, count, start_or_end, boundary_kind, ropeman, Anchor.backwardsWord, self.limit);
}

test moveUp {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars");
    defer ropeman.deinit();

    { // single .point cursor
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // update the initial cursor
        cm.mainCursor().setActiveAnchor(cm, 1, 5);
        try eq(Anchor{ .line = 1, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        // moveUp
        cm.moveUp(1, &ropeman);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveUp(10, &ropeman);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);
    }

    { // uniformed multiple u .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // update the initial cursor
        cm.mainCursor().setActiveAnchor(cm, 1, 5);
        try eq(Anchor{ .line = 1, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        // add 2nd cursor
        try cm.addPointCursor(2, 5, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 1, .col = 5 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 5 }, cm.cursors.values()[1].start);

        // moveUp
        cm.moveUp(1, &ropeman);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 5 }, cm.cursors.values()[1].start);

        // moveUp again, cursors should merge due to overlap
        cm.moveUp(1, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[0].start);

        cm.moveUp(100, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[0].start);
    }
}

test moveDown {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars");
    defer ropeman.deinit();

    { // single .point cursor
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        cm.moveDown(1, &ropeman);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveDown(1, &ropeman);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveDown(100, &ropeman);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);
    }

    { // 2x uniformed .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 2nd cursor
        try cm.addPointCursor(1, 0, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[1].start);

        // moveDown
        cm.moveDown(1, &ropeman);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[1].start);

        // moveDown again, cursors should merge due to overlap
        cm.moveDown(1, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[0].start);
    }

    { // 3x uniformed .point cursors, 2 will collide, 1 won't
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 2nd & 3rd cursors
        try cm.addPointCursor(1, 5, true);
        try cm.addPointCursor(1, 0, true);
        try eqSlice(usize, &.{ 0, 2, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 1, .col = 5 }, cm.cursors.values()[2].start);

        // moveDown
        cm.moveDown(1, &ropeman);
        try eqSlice(usize, &.{ 0, 2, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 2, .col = 5 }, cm.cursors.values()[2].start);

        // moveDown again, cursors should merge due to overlap
        cm.moveDown(1, &ropeman);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 5 }, cm.cursors.values()[1].start);
    }
}

test moveRight {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nbye");
    defer ropeman.deinit();

    { // single .point cursor
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        cm.moveRight(1, &ropeman);
        try eq(Anchor{ .line = 0, .col = 1 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveRight(2, &ropeman);
        try eq(Anchor{ .line = 0, .col = 3 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveRight(3, &ropeman);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.mainCursor().activeAnchor(cm).*);

        cm.moveRight(100, &ropeman);
        try eq(Anchor{ .line = 0, .col = 10 }, cm.mainCursor().activeAnchor(cm).*);
        try eq('d', "hello world"[10]);
    }

    { // multiple uniformed .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 3 more cursors
        try cm.addPointCursor(0, 5, true);
        try cm.addPointCursor(0, 3, true);
        try cm.addPointCursor(1, 1, true);
        try eqSlice(usize, &.{ 0, 2, 1, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 3 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 1 }, cm.cursors.values()[3].start);

        // moveRight
        cm.moveRight(1, &ropeman);
        try eqSlice(usize, &.{ 0, 2, 1, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 1 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 4 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[3].start);

        // moveRight, cursor id=3 stuck at limit '2'
        cm.moveRight(1, &ropeman);
        try eqSlice(usize, &.{ 0, 2, 1, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 2 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 7 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[3].start);

        // moveRight, cursor id=1 stuct at limit '10'
        cm.moveRight(4, &ropeman);
        try eqSlice(usize, &.{ 0, 2, 1, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 9 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 10 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[3].start);

        // moveRight, cursor id=2 gets merged with id=1
        cm.moveRight(1, &ropeman);
        try eqSlice(usize, &.{ 0, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 7 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 10 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[2].start);

        // moveRight, cursor id=0 gets merged with id=2
        cm.moveRight(10, &ropeman);
        try eqSlice(usize, &.{ 0, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 10 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[1].start);
    }
}

test moveLeft {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nbye");
    defer ropeman.deinit();

    { // multiple uniformed .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // update 1st cursor
        cm.mainCursor().setActiveAnchor(cm, 0, 5);

        // add 3 more cursors
        try cm.addPointCursor(0, 2, true);
        try cm.addPointCursor(0, 7, true);
        try cm.addPointCursor(1, 2, true);
        try eqSlice(usize, &.{ 1, 0, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 2 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 7 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 2 }, cm.cursors.values()[3].start);

        // moveLeft
        cm.moveLeft(1, &ropeman);
        try eqSlice(usize, &.{ 1, 0, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 1 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 4 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 1 }, cm.cursors.values()[3].start);

        // moveLeft
        cm.moveLeft(1, &ropeman);
        try eqSlice(usize, &.{ 1, 0, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 3 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[3].start);

        // moveLeft by 3, cursor id=0 gets merged with cursor id=1 due to overlap
        cm.moveLeft(3, &ropeman);
        try eqSlice(usize, &.{ 1, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 2 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[2].start);

        // moveLeft by 100, cursor id=2 gets merged with cursor id=1 due to overlap
        cm.moveLeft(100, &ropeman);
        try eqSlice(usize, &.{ 1, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[1].start);
    }
}

test forwardWord {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars");
    defer ropeman.deinit();

    { // single .point cursor
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // forwardWord
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[0].start);

        cm.forwardWord(.start, .word, 1, &ropeman);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[0].start);
    }

    { // multiple uniformed .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 2nd cursor
        try cm.addPointCursor(0, 6, true);
        try cm.addPointCursor(1, 0, true);
        try cm.addPointCursor(2, 0, true);
        try eqSlice(usize, &.{ 0, 1, 2, 3 }, cm.cursors.keys());
        try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[3].start);

        // forwardWord
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eq(Anchor{ .line = 0, .col = 6 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 1, .col = 6 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 2, .col = 6 }, cm.cursors.values()[3].start);

        // forwardWord
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 1, .col = 6 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[3].start);

        // forwardWord, cursor id=3 stays at eol
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eq(Anchor{ .line = 1, .col = 6 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 2, .col = 6 }, cm.cursors.values()[2].start);
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[3].start);

        // forwardWord, cursor id=3 gets merged with id=2
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eqSlice(usize, &.{ 0, 1, 2 }, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 6 }, cm.cursors.values()[1].start);
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[2].start);

        // forwardWord, cursor id=2 gets merged with id=1
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 6 }, cm.cursors.values()[0].start);
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[1].start);

        // forwardWord, cursor id=1 gets merged with id=0
        cm.forwardWord(.start, .word, 1, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[0].start);

        // forwardWord, stays the same due to reached end of file
        cm.forwardWord(.start, .word, 100, &ropeman);
        try eqSlice(usize, &.{0}, cm.cursors.keys());
        try eq(Anchor{ .line = 2, .col = 9 }, cm.cursors.values()[0].start);
    }
}

test "hjkl with uniform_mode == .single" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhello venus\nhello mars\nclub penguin");
    defer ropeman.deinit();

    var cm = try CursorManager.create(testing_allocator);
    defer cm.destroy();
    cm.activateSingleMode();

    // add 2 more cursors
    try cm.addPointCursor(0, 5, true);
    try cm.addPointCursor(1, 0, true);
    try eq(2, cm.main_cursor_id);
    try eqSlice(usize, &.{ 0, 1, 2 }, cm.cursors.keys());
    try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
    try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[1].start);
    try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[2].start);

    // moveDown, only cursor id=2 moves
    cm.moveDown(1, &ropeman);
    try eqSlice(usize, &.{ 0, 1, 2 }, cm.cursors.keys());
    try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
    try eq(Anchor{ .line = 0, .col = 5 }, cm.cursors.values()[1].start);
    try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[2].start);

    // moveDown, only cursor id=1 moves
    cm.setActiveCursor(1);
    cm.moveDown(1, &ropeman);
    try eqSlice(usize, &.{ 0, 1, 2 }, cm.cursors.keys());
    try eq(Anchor{ .line = 0, .col = 0 }, cm.cursors.values()[0].start);
    try eq(Anchor{ .line = 1, .col = 5 }, cm.cursors.values()[1].start);
    try eq(Anchor{ .line = 2, .col = 0 }, cm.cursors.values()[2].start);

    // back to uniformed mode
    cm.activateUniformedMode();
    cm.moveDown(1, &ropeman);
    try eqSlice(usize, &.{ 0, 1, 2 }, cm.cursors.keys());
    try eq(Anchor{ .line = 1, .col = 0 }, cm.cursors.values()[0].start);
    try eq(Anchor{ .line = 2, .col = 5 }, cm.cursors.values()[1].start);
    try eq(Anchor{ .line = 3, .col = 0 }, cm.cursors.values()[2].start);
}

///////////////////////////// moveCursorWithCallback

const VimCallback = *const fn (
    anchor: *Anchor,
    a: Allocator,
    count: usize,
    start_or_end: Anchor.StartOrEnd,
    boundary_kind: Anchor.BoundaryKind,
    ropeman: *const RopeMan,
    limit: Limit,
) void;

fn moveCursorWithVimCallback(
    self: *@This(),
    a: Allocator,
    count: usize,
    start_or_end: Anchor.StartOrEnd,
    boundary_kind: Anchor.BoundaryKind,
    ropeman: *const RopeMan,
    cb: VimCallback,
    limit: Limit,
) void {
    defer self.just_moved = true;

    // move all cursors
    switch (self.uniform_mode) {
        .uniformed => {
            for (self.cursors.values()) |*cursor| {
                cb(cursor.activeAnchor(self), a, count, start_or_end, boundary_kind, ropeman, limit);
                cursor.ensureAnchorOrder(self);
            }
        },
        .single => {
            cb(self.mainCursor().activeAnchor(self), a, count, start_or_end, boundary_kind, ropeman, limit);
            self.mainCursor().ensureAnchorOrder(self);
        },
    }

    // handle collisions
    self.mergeCursorsIfOverlap();
}

const HJKLCallback = *const fn (anchor: *Anchor, count: usize, ropeman: *const RopeMan, limit: Limit) void;

fn moveCursorWithHJKLCallback(self: *@This(), count: usize, ropeman: *const RopeMan, cb: HJKLCallback, limit: Limit) void {
    defer self.just_moved = true;

    // move all cursors
    switch (self.uniform_mode) {
        .uniformed => {
            for (self.cursors.values()) |*cursor| {
                cb(cursor.activeAnchor(self), count, ropeman, limit);
                cursor.ensureAnchorOrder(self);
            }
        },
        .single => {
            cb(self.mainCursor().activeAnchor(self), count, ropeman, limit);
            self.mainCursor().ensureAnchorOrder(self);
        },
    }

    // handle collisions
    self.mergeCursorsIfOverlap();
}

fn mergeCursorsIfOverlap(self: *@This()) void {
    var i: usize = self.cursors.values().len;
    while (i > 0) {
        i -= 1;
        self._mergeTwoCursorsIfOverlaps(i);
    }
}

fn _mergeTwoCursorsIfOverlaps(self: *@This(), i: usize) void {
    const cursors = self.cursors.values();
    assert(cursors.len > 0);
    assert(i < cursors.len);

    if (cursors.len == 0 or i >= cursors.len - 1) return;

    const curr = cursors[i];
    const next = cursors[i + 1];

    switch (self.cursor_mode) {
        .point => if (curr.start.isEqual(next.start)) self.cursors.orderedRemoveAt(i + 1),
        .range => {
            assert(curr.start.isBeforeOrEqual(curr.end));
            assert(next.start.isBeforeOrEqual(next.end));

            if (curr.rangeOverlapsWith(next)) {
                const start = if (next.start.isBefore(curr.start)) next.start else curr.start;
                const end = if (next.end.isBefore(curr.end)) curr.end else next.end;

                self.cursors.values()[i].start = start;
                self.cursors.values()[i].end = end;

                self.cursors.orderedRemoveAt(i + 1);
            }
        },
    }
}

///////////////////////////// CursorMap / CursorMapSortContext / CursorMapBinarySearchContext

const CursorMap = std.AutoArrayHashMap(usize, Cursor);
const CursorMapContext = struct {
    cursors: []Cursor,

    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
        const a = ctx.cursors[a_index].start;
        const b = ctx.cursors[b_index].start;
        if (a.line == b.line) return a.col < b.col;
        return a.line < b.line;
    }

    pub fn order(a: Cursor, b: Cursor) std.math.Order {
        if (a.start.line == b.start.line) return std.math.order(a.start.col, b.start.col);
        return std.math.order(a.start.line, b.start.line);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Cursor

const UniformMode = enum { single, uniformed };
const CursorMode = enum { point, range };
const InsertDestination = enum { current, after_start, after_going };

const Cursor = struct {
    start: Anchor,
    end: Anchor,

    current_anchor: enum { start, end } = .start,

    pub fn setActiveAnchor(self: *@This(), cm: *const CursorManager, line: usize, col: usize) void {
        self.activeAnchor(cm).set(line, col);
    }

    pub fn setRange(self: *@This(), start: struct { usize, usize }, end: struct { usize, usize }) !void {
        self.start.line, self.start.col = start;
        self.end.line, self.end.col = end;
    }

    pub fn activeAnchor(self: *@This(), cm: *const CursorManager) *Anchor {
        return switch (cm.cursor_mode) {
            .point => &self.start,
            .range => if (self.current_anchor == .start) &self.start else &self.end,
        };
    }

    fn ensureAnchorOrder(self: *@This(), cm: *const CursorManager) void {
        if (cm.cursor_mode == .point) return;
        if (self.end.isBefore(self.start)) {
            const start_cpy = self.start;
            self.start = self.end;
            self.end = start_cpy;

            self.current_anchor = switch (self.current_anchor) {
                .start => .end,
                .end => .start,
            };
        }
    }

    fn rangeOverlapsWith(self: *const @This(), other: @This()) bool {
        return (other.start.isBeforeOrEqual(self.start) or
            other.start.isBeforeOrEqual(self.end) or
            other.end.isBeforeOrEqual(self.start) or
            other.end.isBeforeOrEqual(self.end));
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Anchor

const Anchor = struct {
    line: usize,
    col: usize,

    fn set(self: *@This(), line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }

    fn isBeforeOrEqual(self: *const @This(), other: @This()) bool {
        if (self.line == other.line) return self.col <= other.col;
        return self.line < other.line;
    }

    fn isEqual(self: *const @This(), other: @This()) bool {
        return self.line == other.line and self.col == other.col;
    }

    fn isBefore(self: *const @This(), other: @This()) bool {
        if (self.line == other.line) return self.col < other.col;
        return self.line < other.line;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Text Objects

    ///////////////////////////// word

    const WordTextObjectCtx = struct {
        boundary_kind: WordBoundaryKind,
        ropeman: *const RopeMan,
        anchor: Anchor,
        target: TargetCharKind = undefined,
        buf: [3]u8 = undefined,

        const WordBoundaryKind = enum { word, WORD };

        const TargetCharKind = enum {
            symbol_or_char,
            spacing_or_symbol,
            spacing_or_char,
        };

        fn init(ropeman: *const RopeMan, anchor: Anchor, boundary_kind: WordBoundaryKind) WordTextObjectCtx {
            var self = WordTextObjectCtx{ .ropeman = ropeman, .anchor = anchor, .boundary_kind = boundary_kind };
            self.target = self.getTargetCharKind();
            return self;
        }

        fn produceRange(self: *@This()) ?RopeMan.CursorRange {
            var start = RopeMan.CursorPoint{ .line = self.anchor.line, .col = 0 };
            var end = RopeMan.CursorPoint{ .line = self.anchor.line, .col = self.anchor.col + 1 };

            const backwards_result = self.ropeman.seekBackwards(self.anchor.line, self.anchor.col, touchedWordBoundary, self, true) catch return null;
            if (backwards_result.point) |back_point| start = .{ .line = back_point.line, .col = back_point.col + 1 };

            const forward_result = self.ropeman.seekForward(self.anchor.line, self.anchor.col, touchedWordBoundary, self, true) catch return null;
            if (forward_result.point) |forward_point| {
                end = forward_point;
            } else if (forward_result.eol_colnr) |eol_colnr| {
                end = RopeMan.CursorPoint{ .line = self.anchor.line, .col = eol_colnr };
            }

            return RopeMan.CursorRange{ .start = start, .end = end };
        }

        fn getTargetCharKind(self: *@This()) TargetCharKind {
            const cp = self.ropeman.getCharacterAt(.{ .line = self.anchor.line, .col = self.anchor.col }, &self.buf);
            const from = getCharKind(u21, cp);
            return switch (from) {
                .not_found => unreachable,
                .spacing => TargetCharKind.symbol_or_char,
                .char => TargetCharKind.spacing_or_symbol,
                .symbol => TargetCharKind.spacing_or_char,
            };
        }

        fn touchedWordBoundary(ctx: ?*anyopaque, cp: u21) bool {
            assert(ctx != null);
            if (ctx == null) return false;

            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const kind = getCharKind(u21, cp);

            switch (self.boundary_kind) {
                .word => {
                    return switch (self.target) {
                        .symbol_or_char => kind != .spacing,
                        .spacing_or_symbol => kind == .spacing or kind == .symbol,
                        .spacing_or_char => kind == .spacing or kind == .char,
                    };
                },
                .WORD => return kind == .spacing,
            }
        }
    };

    fn getInWordTextObject(self: *const @This(), ropeman: *const RopeMan, boundary_kind: WordTextObjectCtx.WordBoundaryKind) ?RopeMan.CursorRange {
        var ctx = WordTextObjectCtx.init(ropeman, self.*, boundary_kind);
        return ctx.produceRange();
    }

    test getInWordTextObject {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string,
            \\const str = "something-small;not_sure";
            \\const b = 10;
        );
        defer ropeman.deinit();

        try testGetWordTextObject(.{ 0, 0, 0, 5 }, .{ 0, 0 }, &ropeman, .word);
        try testGetWordTextObject(.{ 0, 0, 0, 5 }, .{ 0, 1 }, &ropeman, .word);
        try testGetWordTextObject(.{ 1, 6, 1, 7 }, .{ 1, 6 }, &ropeman, .word);
    }

    fn testGetWordTextObject(expected: ?struct { usize, usize, usize, usize }, a: struct { usize, usize }, ropeman: *const RopeMan, boundary_kind: WordTextObjectCtx.WordBoundaryKind) !void {
        const anchor = Anchor{ .line = a[0], .col = a[1] };
        if (expected) |e| {
            const range = RopeMan.CursorRange{ .start = .{ .line = e[0], .col = e[1] }, .end = .{ .line = e[2], .col = e[3] } };
            const result = anchor.getInWordTextObject(ropeman, boundary_kind);
            // std.debug.print("result: {any}\n", .{result});
            try eq(range, result);
            return;
        }
        try eq(null, anchor.getInWordTextObject(ropeman, boundary_kind));
    }

    ///////////////////////////// '

    fn getPairedTextObjectOnCurrentLine(self: *const @This(), ropeman: *const RopeMan, cb: SeekCallback, ctx: ?*anyopaque) ?RopeMan.CursorRange {
        var start: ?RopeMan.CursorPoint = null;

        const backwards_result = ropeman.seekBackwards(self.line, self.col, cb, ctx, true) catch return null;
        if (backwards_result.point) |back_point| {
            if (backwards_result.init_matches) {
                return RopeMan.CursorRange{
                    .start = back_point,
                    .end = .{ .line = self.line, .col = self.col },
                };
            }
            start = back_point;
        }

        const first_forward_result = ropeman.seekForward(self.line, self.col, cb, ctx, true) catch return null;
        if (first_forward_result.point) |first_fwd_point| {
            if (start != null) {
                return RopeMan.CursorRange{
                    .start = start.?,
                    .end = first_fwd_point,
                };
            }
            if (first_forward_result.init_matches) {
                return RopeMan.CursorRange{
                    .start = .{ .line = self.line, .col = self.col },
                    .end = first_fwd_point,
                };
            }
            start = first_fwd_point;
        }

        const first_point = first_forward_result.point orelse return null;
        assert(start != null);
        const second_forward_result = ropeman.seekForward(first_point.line, first_point.col, cb, ctx, true) catch return null;
        if (second_forward_result.point) |second_fwd_point| {
            return RopeMan.CursorRange{
                .start = start.?,
                .end = second_fwd_point,
            };
        }
        return null;
    }

    fn isSingleQuote(_: ?*anyopaque, cp: u21) bool {
        return cp == '\'';
    }

    fn getSingleQuoteTextObject(self: *const @This(), ropeman: *const RopeMan) ?RopeMan.CursorRange {
        return self.getPairedTextObjectOnCurrentLine(ropeman, isSingleQuote, null);
    }

    test getSingleQuoteTextObject {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string,
            \\I am 'John' goin' I live in 'New York'.
            \\You are 'Jane' and you live in 'Canada'.
        );
        defer ropeman.deinit();

        // line 0
        try testGetSingleQuote(.{ 0, 5, 0, 10 }, .{ 0, 0 }, &ropeman);
        try testGetSingleQuote(.{ 0, 5, 0, 10 }, .{ 0, 4 }, &ropeman);
        try testGetSingleQuote(.{ 0, 5, 0, 10 }, .{ 0, 5 }, &ropeman);
        try testGetSingleQuote(.{ 0, 5, 0, 10 }, .{ 0, 9 }, &ropeman);
        try testGetSingleQuote(.{ 0, 5, 0, 10 }, .{ 0, 10 }, &ropeman);

        try testGetSingleQuote(.{ 0, 10, 0, 16 }, .{ 0, 11 }, &ropeman);
        try testGetSingleQuote(.{ 0, 10, 0, 16 }, .{ 0, 15 }, &ropeman);
        try testGetSingleQuote(.{ 0, 10, 0, 16 }, .{ 0, 16 }, &ropeman);

        try testGetSingleQuote(.{ 0, 16, 0, 28 }, .{ 0, 17 }, &ropeman);
        try testGetSingleQuote(.{ 0, 16, 0, 28 }, .{ 0, 27 }, &ropeman);
        try testGetSingleQuote(.{ 0, 16, 0, 28 }, .{ 0, 28 }, &ropeman);

        try testGetSingleQuote(.{ 0, 28, 0, 37 }, .{ 0, 29 }, &ropeman);
        try testGetSingleQuote(.{ 0, 28, 0, 37 }, .{ 0, 37 }, &ropeman);
        try testGetSingleQuote(null, .{ 0, 38 }, &ropeman);

        // line 1
        try testGetSingleQuote(.{ 1, 8, 1, 13 }, .{ 1, 0 }, &ropeman);
        try testGetSingleQuote(.{ 1, 8, 1, 13 }, .{ 1, 13 }, &ropeman);

        try testGetSingleQuote(.{ 1, 13, 1, 31 }, .{ 1, 14 }, &ropeman);
        try testGetSingleQuote(.{ 1, 13, 1, 31 }, .{ 1, 31 }, &ropeman);

        try testGetSingleQuote(.{ 1, 31, 1, 38 }, .{ 1, 32 }, &ropeman);
        try testGetSingleQuote(.{ 1, 31, 1, 38 }, .{ 1, 38 }, &ropeman);
        try testGetSingleQuote(null, .{ 1, 39 }, &ropeman);
    }

    fn testGetSingleQuote(expected: ?struct { usize, usize, usize, usize }, a: struct { usize, usize }, ropeman: *const RopeMan) !void {
        const anchor = Anchor{ .line = a[0], .col = a[1] };
        if (expected) |e| {
            const range = RopeMan.CursorRange{
                .start = .{ .line = e[0], .col = e[1] },
                .end = .{ .line = e[2], .col = e[3] },
            };
            const result = anchor.getSingleQuoteTextObject(ropeman);
            try eq(range, result);
            return;
        }
        try eq(null, anchor.getSingleQuoteTextObject(ropeman));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Movement

    // hjkl

    fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.line -|= by;
        self.restrictCol(ropeman);
        self.restrictToLimit(limit);
    }

    fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.line += by;
        const nol = ropeman.getNumOfLines();
        if (self.line >= nol) self.line = nol -| 1;
        self.restrictCol(ropeman);
        self.restrictToLimit(limit);
    }

    fn moveLeft(self: *@This(), by: usize, _: *const RopeMan, limit: Limit) void {
        self.col -|= by;
        self.restrictToLimit(limit);
    }

    fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.col += by;
        self.restrictCol(ropeman);
        self.restrictToLimit(limit);
    }

    // AFTER Insert Mode

    fn moveRightForAFTERInsertMode(self: *@This(), by: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.col += by;
        self.restrictColNoc(ropeman);
        self.restrictToLimit(limit);
    }

    // bol / eol

    fn moveToBeginningOfLine(self: *@This(), _: usize, _: *const RopeMan, limit: Limit) void {
        self.col = 0;
        self.restrictToLimit(limit);
    }

    fn moveToEndOfLine(self: *@This(), _: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.col = ropeman.getNumOfCharsInLine(self.line) -| 1;
        self.restrictToLimit(limit);
    }

    fn moveToFirstNonSpaceCharacterOfLine(self: *@This(), _: usize, ropeman: *const RopeMan, limit: Limit) void {
        self.col = ropeman.getColnrOfFirstNonSpaceCharInLine(self.line);
        self.restrictToLimit(limit);
    }

    // restrictCol

    fn restrictCol(self: *@This(), ropeman: *const RopeMan) void {
        const noc = ropeman.getNumOfCharsInLine(self.line);
        if (self.col >= noc) self.col = noc -| 1;
    }

    fn restrictColNoc(self: *@This(), ropeman: *const RopeMan) void {
        const noc = ropeman.getNumOfCharsInLine(self.line);
        if (self.col >= noc) self.col = noc;
    }

    // restrictToLimit

    fn restrictToLimit(self: *@This(), limit: Limit) void {
        if (self.line < limit.start_line) {
            self.line = limit.start_line;
            return;
        }
        if (self.line > limit.end_line) {
            self.line = limit.end_line;
            return;
        }
    }

    ///////////////////////////// b/B

    pub fn backwardsWord(
        self: *@This(),
        a: Allocator,
        count: usize,
        start_or_end: StartOrEnd,
        boundary_kind: BoundaryKind,
        ropeman: *const RopeMan,
        limit: Limit,
    ) void {
        for (0..count) |_| {
            self.backwardsWordSingleTime(a, start_or_end, boundary_kind, ropeman);
            self.restrictToLimit(limit);
        }
    }

    fn backwardsWordSingleTime(self: *@This(), a: Allocator, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        var start_char_kind = CharKind.not_found;
        var linenr: usize = self.line + 1;
        var first_time = true;
        while (linenr > 0) {
            defer first_time = false;
            linenr -= 1;
            const line = ropeman.getLineAlloc(a, linenr, 1024) catch return;
            defer a.free(line);

            self.line = linenr;
            if (!first_time) self.col = line.len;
            switch (findBackwardsTargetInLine(self.col, first_time, line, start_or_end, boundary_kind, &start_char_kind)) {
                .not_found => {
                    if (linenr == 0) self.col = 0;
                },
                .found => |colnr| {
                    self.col = colnr;
                    return;
                },
            }
        }
    }

    fn findBackwardsTargetInLine(cursor_col: usize, first_time: bool, line: []const u8, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, start_char_kind: *CharKind) FindWordInLineResult {
        if (line.len == 0 or cursor_col == 0) return .not_found;

        var noc: usize = 0;
        var offset = line.len - 1;
        var col: usize = 0;
        var stop_incrementing_col = false;

        var iter = code_point.Iterator{ .bytes = line };
        while (iter.next()) |cp| {
            defer {
                if (!stop_incrementing_col) col += 1;
                noc += 1;
            }
            if (start_char_kind.* == .not_found and col == cursor_col) {
                start_char_kind.* = getCharKind(u21, cp.code);
                offset = cp.offset;
                col += 1;
                stop_incrementing_col = true;
            }
        }
        assert(col > 0);
        col -= 1;
        const last_col = col;

        var shifted_back_by_1 = false;
        var encountered_non_spacing = false;
        var should_break = false;
        var last_char_kind = CharKind.not_found;

        while (!should_break) {
            defer offset -|= 1;

            const cp_len = getCodePointLenFromByte(line[offset]);
            if (cp_len == 0) continue;

            if (!shifted_back_by_1 and first_time) {
                shifted_back_by_1 = true;
                col -= 1;
                last_char_kind = getCharKind(u8, line[offset]);
                continue;
            }

            defer col -|= 1;
            should_break = col == 0;

            const char_kind = getCharKind(u8, line[offset]);
            defer last_char_kind = char_kind;
            defer switch (char_kind) {
                .not_found => unreachable,
                .spacing => {},
                .symbol => encountered_non_spacing = true,
                .char => encountered_non_spacing = true,
            };

            switch (start_or_end) {
                .start => {
                    if (!encountered_non_spacing and cursor_col < line.len) continue;
                    if (col == 0 and char_kind == last_char_kind) return .{ .found = 0 };

                    switch (char_kind) {
                        .not_found => unreachable,
                        .spacing => if (last_char_kind != .not_found and last_char_kind != .spacing) return .{ .found = col + 1 },
                        .char => if (boundary_kind == .word and last_char_kind == .symbol) return .{ .found = col + 1 },
                        .symbol => if (boundary_kind == .word and last_char_kind == .char) return .{ .found = col + 1 },
                    }
                },
                .end => {
                    if (cursor_col > last_col) return .{ .found = noc - 1 };
                    switch (char_kind) {
                        .not_found => unreachable,
                        .spacing => {},
                        .char => if (last_char_kind == .spacing or (boundary_kind == .word and last_char_kind == .symbol)) return .{ .found = col },
                        .symbol => if (last_char_kind == .spacing or (boundary_kind == .word and last_char_kind == .char)) return .{ .found = col },
                    }
                },
            }
        }

        return .not_found;
    }

    fn getCodePointLenFromByte(byte: u8) usize {
        if (byte < 128) return 1;
        return switch (byte) {
            0b1100_0000...0b1101_1111 => 2,
            0b1110_0000...0b1110_1111 => 3,
            0b1111_0000...0b1111_0111 => 4,
            else => 0,
        };
    }

    ///////////////////////////// w/W e/E

    pub fn forwardWord(
        self: *@This(),
        a: Allocator,
        count: usize,
        start_or_end: StartOrEnd,
        boundary_kind: BoundaryKind,
        ropeman: *const RopeMan,
        limit: Limit,
    ) void {
        for (0..count) |_| {
            self.forwardWordSingleTime(a, start_or_end, boundary_kind, ropeman);
            self.restrictToLimit(limit);
        }
    }

    fn forwardWordSingleTime(self: *@This(), a: Allocator, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        var start_char_kind = CharKind.not_found;
        var passed_a_space = false;

        const num_of_lines = ropeman.getNumOfLines();
        for (self.line..num_of_lines) |linenr| {
            const line = ropeman.getLineAlloc(a, linenr, 1024) catch return;
            defer a.free(line);

            self.line = linenr;
            switch (findForwardTargetInLine(self.col, line, start_or_end, boundary_kind, &start_char_kind, &passed_a_space)) {
                .not_found => self.col = if (self.line + 1 >= num_of_lines) line.len -| 1 else 0,
                .found => |colnr| {
                    self.col = colnr;
                    return;
                },
            }
        }
    }

    const StartOrEnd = enum { start, end };
    const BoundaryKind = enum { word, BIG_WORD };
    const FindWordInLineResult = union(enum) { not_found, found: usize };
    fn findForwardTargetInLine(cursor_col: usize, line: []const u8, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, start_char_kind: *CharKind, passed_a_space: *bool) FindWordInLineResult {
        if (start_char_kind.* != .not_found) passed_a_space.* = true;
        if (line.len == 0) return .not_found;

        var iter = code_point.Iterator{ .bytes = line };
        while (iter.next()) |cp| {
            const i = iter.i - 1;
            const char_kind = getCharKind(u8, line[cp.offset]);

            if (start_char_kind.* == .not_found) {
                if (i == cursor_col) start_char_kind.* = char_kind;
                continue;
            }

            switch (start_or_end) {
                .start => {
                    switch (char_kind) {
                        .not_found => unreachable,
                        .spacing => passed_a_space.* = true,
                        .char => if (passed_a_space.* or (boundary_kind == .word and start_char_kind.* == .symbol)) return .{ .found = i },
                        .symbol => if (passed_a_space.* or (boundary_kind == .word and start_char_kind.* == .char)) return .{ .found = i },
                    }
                },
                .end => {
                    if (char_kind == .spacing) continue;
                    const peek_result = iter.peek() orelse return .{ .found = i };
                    const peek_char_type = getCharKind(u8, line[peek_result.offset]);
                    switch (peek_char_type) {
                        .not_found => unreachable,
                        .spacing => return .{ .found = i },
                        else => if (boundary_kind == .word and char_kind != peek_char_type) return .{ .found = i },
                    }
                },
            }
        }

        return .not_found;
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// hjkl

test "Anchor - basic hjkl movements" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hi\nworld\nhello\nx");
    defer ropeman.deinit();
    var c = Anchor{ .line = 0, .col = 0 };
    const no_limit = Limit{};

    // moveRight()
    {
        c.moveRight(1, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveRight(2, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveRight(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 1 }, c);
    }

    // moveLeft()
    {
        c.moveLeft(1, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 0 }, c);
        c.moveLeft(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 0 }, c);
    }

    // moveDown()
    {
        c.moveRight(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveDown(1, &ropeman, no_limit);
        try eq(Anchor{ .line = 1, .col = 1 }, c);

        c.moveDown(1, &ropeman, no_limit);
        try eq(Anchor{ .line = 2, .col = 1 }, c);

        c.moveDown(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 3, .col = 0 }, c);
    }

    // moveUp()
    {
        c.moveUp(1, &ropeman, no_limit);
        try eq(Anchor{ .line = 2, .col = 0 }, c);

        c.moveRight(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 2, .col = 4 }, c);

        c.moveUp(100, &ropeman, no_limit);
        try eq(Anchor{ .line = 0, .col = 1 }, c);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Vim Movements

test "Anchor - backwardsWord()" {
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 1, .col = 8 };
            try testBackwardsWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 1, .col = 3 },
                .{ .line = 1, .col = 0 },
                .{ .line = 0, .col = 6 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello; world;\nhi||;; venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 1, .col = "hi||;; venus".len };
            try testBackwardsWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 1, .col = 7 },
                .{ .line = 1, .col = 2 },
                .{ .line = 1, .col = 0 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello; world;;\nhi||;; venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 1, .col = "hi||;; venus".len };
            try testBackwardsWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 1, .col = 7 },
                .{ .line = 1, .col = 2 },
                .{ .line = 1, .col = 0 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 0 },
            });
        }
        {
            var c = Anchor{ .line = 1, .col = "hi||;; venus".len };
            try testBackwardsWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 1, .col = 7 },
                .{ .line = 1, .col = 0 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "/888/");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = "/888/".len };
            try testBackwardsWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 1 },
                .{ .line = 0, .col = 0 },
            });
        }
    }

    // .end
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello; world;\nhi||| venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 1, .col = "hi||| venus".len - 1 };
            try testBackwardsWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 1, .col = 4 },
                .{ .line = 1, .col = 1 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 11 },
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 0 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 1, .col = "hi||| venus".len - 1 };
            try testBackwardsWord(&c, .end, .BIG_WORD, &ropeman, &.{
                .{ .line = 1, .col = 4 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "okay bye\nhello; world;\nhi||| venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 2, .col = "hi||| venus".len - 1 };
            try testBackwardsWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 2, .col = 4 },
                .{ .line = 2, .col = 1 },
                .{ .line = 1, .col = 12 },
                .{ .line = 1, .col = 11 },
                .{ .line = 1, .col = 5 },
                .{ .line = 1, .col = 4 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 3 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one;two--3|||four;\nhello there");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 1, .col = 0 };

            try testBackwardsWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 0, .col = 17 },
                .{ .line = 0, .col = 16 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 9 },
                .{ .line = 0, .col = 8 },
                .{ .line = 0, .col = 6 },
                .{ .line = 0, .col = 3 },
                .{ .line = 0, .col = 2 },
                .{ .line = 0, .col = 0 },
            });
        }
    }
}

fn testBackwardsWord(anchor: *Anchor, start_or_end: Anchor.StartOrEnd, boundary_kind: Anchor.BoundaryKind, ropeman: *const RopeMan, expected: []const Anchor) !void {
    for (expected) |e| {
        anchor.backwardsWord(testing_allocator, 1, start_or_end, boundary_kind, ropeman, Limit{});
        try eq(e, anchor.*);
    }
}

test "Anchor - forwardWord()" {
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 0, .col = 6 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 3 },
                .{ .line = 1, .col = 7 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello; world;\nhi venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 12 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 3 },
                .{ .line = 1, .col = 7 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 7 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 3 },
                .{ .line = 1, .col = 7 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;  world;\nhi   venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 0, .col = 5 },
                .{ .line = 0, .col = 8 },
                .{ .line = 0, .col = 13 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 5 },
                .{ .line = 1, .col = 9 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 8 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 5 },
                .{ .line = 1, .col = 9 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one;two--3|||four;");
        defer ropeman.deinit();
        { // .word
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .word, &ropeman, &.{
                .{ .line = 0, .col = 3 },
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 7 },
                .{ .line = 0, .col = 9 },
                .{ .line = 0, .col = 10 },
                .{ .line = 0, .col = 13 },
                .{ .line = 0, .col = 17 },
                .{ .line = 0, .col = 17 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 17 },
            });
        }
    }

    ///////////////////////////// .end

    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 10 },
                .{ .line = 1, .col = 1 },
                .{ .line = 1, .col = 7 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;; world;\nhi;;; venus");
        defer ropeman.deinit();
        {
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 6 },
                .{ .line = 0, .col = 12 },
                .{ .line = 0, .col = 13 },
                .{ .line = 1, .col = 1 },
                .{ .line = 1, .col = 4 },
                .{ .line = 1, .col = 10 },
            });
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;;  world;\nhi;;;   venus");
        defer ropeman.deinit();
        { // .word
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .end, .word, &ropeman, &.{
                .{ .line = 0, .col = 4 },
                .{ .line = 0, .col = 6 },
                .{ .line = 0, .col = 13 },
                .{ .line = 0, .col = 14 },
                .{ .line = 1, .col = 1 },
                .{ .line = 1, .col = 4 },
                .{ .line = 1, .col = 12 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .end, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 6 },
                .{ .line = 0, .col = 14 },
                .{ .line = 1, .col = 4 },
                .{ .line = 1, .col = 12 },
            });
        }
    }
}

fn testForwardWord(anchor: *Anchor, start_or_end: Anchor.StartOrEnd, boundary_kind: Anchor.BoundaryKind, ropeman: *const RopeMan, expected: []const Anchor) !void {
    for (expected) |e| {
        anchor.forwardWord(testing_allocator, 1, start_or_end, boundary_kind, ropeman, Limit{});
        try eq(e, anchor.*);
    }
}

const CharKind = enum { spacing, symbol, char, not_found };

fn getCharKind(T: type, b: T) CharKind {
    return switch (b) {
        ' ' => .spacing,
        '\t' => .spacing,
        '\n' => .spacing,

        '=' => .symbol,
        '"' => .symbol,
        '\'' => .symbol,
        '/' => .symbol,
        '\\' => .symbol,
        '*' => .symbol,
        ':' => .symbol,
        '.' => .symbol,
        ',' => .symbol,
        '(' => .symbol,
        ')' => .symbol,
        '{' => .symbol,
        '}' => .symbol,
        '[' => .symbol,
        ']' => .symbol,
        ';' => .symbol,
        '|' => .symbol,
        '?' => .symbol,
        '&' => .symbol,
        '#' => .symbol,
        '-' => .symbol,

        else => .char,
    };
}

test {
    std.testing.refAllDeclsRecursive(Anchor);
}
