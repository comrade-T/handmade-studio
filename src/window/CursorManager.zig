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

////////////////////////////////////////////////////////////////////////////////////////////// CursorManager

a: Allocator,

cursor_mode: CursorMode = .point,
uniform_mode: UniformMode = .single,

main_cursor_id: usize = 0,
cursor_id_count: usize = 0,
cursors: CursorMap,

pub fn create(a: Allocator) !*CursorManager {
    var self = try a.create(@This());
    self.* = .{
        .a = a,
        .cursors = CursorMap.init(self.a),
    };
    try self.addCursor(0, 0, true);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.cursors.deinit();
    self.a.destroy(self);
}

pub fn mainCursor(self: *@This()) *Cursor {
    return self.cursors.getPtr(self.main_cursor_id) orelse @panic("Unable to get main cursor");
}

pub fn addCursor(self: *@This(), line: usize, col: usize, make_main: bool) !void {
    const new_cursor = Cursor{
        .start = Anchor{ .line = line, .col = col },
        .end = Anchor{ .line = line, .col = col + 1 },
    };

    const existing_index = std.sort.binarySearch(Cursor, new_cursor, self.cursors.values(), {}, CursorMapContext.order);
    if (existing_index != null) return;

    defer self.cursor_id_count += 1;
    try self.cursors.put(self.cursor_id_count, new_cursor);
    if (make_main) self.main_cursor_id = self.cursor_id_count;
    self.cursors.sort(CursorMapContext{ .cursors = self.cursors.values() });
}

test addCursor {
    {
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // initital cursor position is line=0 col=0 on CursorManager.create()
        try eq(1, cm.cursors.values().len);
        try eq(Anchor{ .line = 0, .col = 0 }, cm.mainCursor().activeAnchor(cm).*);

        // add 2nd cursor AFTER the initial cursor
        try cm.addCursor(0, 5, true);
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
        try cm.addCursor(0, 0, true);
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

        try cm.addCursor(0, 0, true);
        try eqSlice(usize, &.{0}, cm.cursors.keys());

        try cm.addCursor(0, 5, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());

        try cm.addCursor(0, 0, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
        try cm.addCursor(0, 5, true);
        try eqSlice(usize, &.{ 0, 1 }, cm.cursors.keys());
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Movement

pub fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithCallback(by, ropeman, Anchor.moveUp);
}

pub fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithCallback(by, ropeman, Anchor.moveDown);
}

pub fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan) void {
    self.moveCursorWithCallback(by, ropeman, Anchor.moveRight);
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

    { // multiple .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // update the initial cursor
        cm.mainCursor().setActiveAnchor(cm, 1, 5);
        try eq(Anchor{ .line = 1, .col = 5 }, cm.mainCursor().activeAnchor(cm).*);

        // add 2nd cursor
        try cm.addCursor(2, 5, true);
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

    { // 2x .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 2nd cursor
        try cm.addCursor(1, 0, true);
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

    { // 3x .point cursors, 2 will collide, 1 won't
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 2nd & 3rd cursors
        try cm.addCursor(1, 5, true);
        try cm.addCursor(1, 0, true);
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

    { // multiple .point cursors
        var cm = try CursorManager.create(testing_allocator);
        defer cm.destroy();

        // add 3 more cursors
        try cm.addCursor(0, 5, true);
        try cm.addCursor(0, 3, true);
        try cm.addCursor(1, 1, true);
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

///////////////////////////// moveCursorWithCallback

const MoveAnchorCallback = *const fn (anchor: *Anchor, by: usize, ropeman: *const RopeMan) void;

fn moveCursorWithCallback(self: *@This(), by: usize, ropeman: *const RopeMan, cb: MoveAnchorCallback) void {
    // move all cursors
    for (self.cursors.values()) |*cursor| {
        cb(cursor.activeAnchor(self), by, ropeman);
        cursor.ensureAnchorOrder(self);
    }

    // handle collisions
    var i: usize = self.cursors.values().len;
    while (i > 0) {
        i -= 1;
        self.mergeCursorsIfOverlaps(i);
    }
}

fn mergeCursorsIfOverlaps(self: *@This(), i: usize) void {
    const cursors = self.cursors.values();
    assert(cursors.len > 0);
    assert(i < cursors.len);

    if (cursors.len == 0 or i >= cursors.len - 1) return;

    const curr = cursors[i];
    const next = cursors[i + 1];

    switch (self.cursor_mode) {
        .point => if (curr.start.isEqual(next.start)) self.cursors.orderedRemoveAt(i + 1),
        .range => {
            assert(curr.start.isBefore(curr.end));
            assert(next.start.isBefore(next.end));

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

    pub fn order(_: void, a: Cursor, b: Cursor) std.math.Order {
        if (a.start.line == b.start.line) return std.math.order(a.start.col, b.start.col);
        return std.math.order(a.start.line, b.start.line);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Cursor

const UniformMode = enum { single, uniformed };
const CursorMode = enum { point, range };

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

    fn activeAnchor(self: *@This(), cm: *const CursorManager) *Anchor {
        return switch (cm.cursor_mode) {
            .point => &self.start,
            .range => if (self.current_anchor == .start) &self.start else &self.end,
        };
    }

    fn ensureAnchorOrder(self: *@This(), cm: *const CursorManager) void {
        if (cm.cursor_mode == .point) return;
        if (self.start.isEqual(self.end)) {
            self.end.col += 1;
            return;
        }
        if (self.end.isBefore(self.start)) {
            const start_cpy = self.start;
            self.start = self.end;
            self.end = start_cpy;
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

    ///////////////////////////// hjkl

    fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line -|= by;
        self.restrictCol(ropeman);
    }

    fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line += by;
        const nol = ropeman.getNumOfLines();
        if (self.line >= nol) self.line = nol -| 1;
        self.restrictCol(ropeman);
    }

    fn moveLeft(self: *@This(), by: usize) void {
        self.col -|= by;
    }

    fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.col += by;
        self.restrictCol(ropeman);
    }

    fn restrictCol(self: *@This(), ropeman: *const RopeMan) void {
        const noc = ropeman.getNumOfCharsInLine(self.line);
        if (self.col >= noc) self.col = noc -| 1;
    }

    ///////////////////////////// b/B

    pub fn backwardsWord(self: *@This(), a: Allocator, count: usize, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        for (0..count) |_| self.backwardsWordSingleTime(a, start_or_end, boundary_kind, ropeman);
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
                    if (!encountered_non_spacing) continue;
                    if (col == 0) return .{ .found = 0 };
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

    pub fn forwardWord(self: *@This(), a: Allocator, count: usize, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        for (0..count) |_| self.forwardWordSingleTime(a, start_or_end, boundary_kind, ropeman);
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
                .not_found => self.col = if (self.line + 1 >= num_of_lines) line.len else 0,
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

test "Anchor - basic hjkl movements" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hi\nworld\nhello\nx");
    defer ropeman.deinit();
    var c = Anchor{ .line = 0, .col = 0 };

    // moveRight()
    {
        c.moveRight(1, &ropeman);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveRight(2, &ropeman);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveRight(100, &ropeman);
        try eq(Anchor{ .line = 0, .col = 1 }, c);
    }

    // moveLeft()
    {
        c.moveLeft(1);
        try eq(Anchor{ .line = 0, .col = 0 }, c);
        c.moveLeft(100);
        try eq(Anchor{ .line = 0, .col = 0 }, c);
    }

    // moveDown()
    {
        c.moveRight(100, &ropeman);
        try eq(Anchor{ .line = 0, .col = 1 }, c);

        c.moveDown(1, &ropeman);
        try eq(Anchor{ .line = 1, .col = 1 }, c);

        c.moveDown(1, &ropeman);
        try eq(Anchor{ .line = 2, .col = 1 }, c);

        c.moveDown(100, &ropeman);
        try eq(Anchor{ .line = 3, .col = 0 }, c);
    }

    // moveUp()
    {
        c.moveUp(1, &ropeman);
        try eq(Anchor{ .line = 2, .col = 0 }, c);

        c.moveRight(100, &ropeman);
        try eq(Anchor{ .line = 2, .col = 4 }, c);

        c.moveUp(100, &ropeman);
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
        anchor.backwardsWord(testing_allocator, 1, start_or_end, boundary_kind, ropeman);
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
                .{ .line = 1, .col = 8 },
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
                .{ .line = 1, .col = 8 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 7 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 3 },
                .{ .line = 1, .col = 8 },
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
                .{ .line = 1, .col = 10 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 8 },
                .{ .line = 1, .col = 0 },
                .{ .line = 1, .col = 5 },
                .{ .line = 1, .col = 10 },
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
                .{ .line = 0, .col = 18 },
            });
        }
        { // .BIG_WORD
            var c = Anchor{ .line = 0, .col = 0 };
            try testForwardWord(&c, .start, .BIG_WORD, &ropeman, &.{
                .{ .line = 0, .col = 18 },
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
        anchor.forwardWord(testing_allocator, 1, start_or_end, boundary_kind, ropeman);
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
