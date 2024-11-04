const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const code_point = @import("code_point");
const RopeMan = @import("RopeMan");

//////////////////////////////////////////////////////////////////////////////////////////////

cursors: ArrayList(Cursor),

const GetNumOfLinesCallback = *const fn (ctx: *anyopaque) usize;
const GetNocInLineCallback = *const fn (ctx: *anyopaque, linenr: usize) usize;
const GetLineCallback = *const fn (ctx: *anyopaque, a: Allocator, linenr: usize) []const u8;

const Cursor = struct {
    line: usize,
    col: usize,

    ///////////////////////////// hjkl

    pub fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line -|= by;
        self.restrictCol(ropeman);
    }

    pub fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line += by;
        const nol = ropeman.getNumOfLines();
        if (self.line >= nol) self.line = nol -| 1;
        self.restrictCol(ropeman);
    }

    pub fn moveLeft(self: *@This(), by: usize) void {
        self.col -|= by;
    }

    pub fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.col += by;
        self.restrictCol(ropeman);
    }

    pub fn restrictCol(self: *@This(), ropeman: *const RopeMan) void {
        const noc = ropeman.getNumOfCharsInLine(self.line);
        if (self.col > noc) self.col = noc;
    }

    ///////////////////////////// w/W

    pub fn forwardWord(self: *@This(), a: Allocator, count: usize, ropeman: *const RopeMan) void {
        for (0..count) |_| self.forwardWordSingleTime(a, ropeman);
    }

    fn forwardWordSingleTime(self: *@This(), a: Allocator, ropeman: *const RopeMan) void {
        var start_col_byte_kind = CharKind.not_found;
        var has_iterated_past_a_space = false;

        const num_of_lines = ropeman.getNumOfLines();
        for (self.line..num_of_lines) |linenr| {
            const line = ropeman.getLineAlloc(a, linenr, 1024) catch return;
            defer a.free(line);

            self.line = linenr;
            switch (findForwardTargetInLine(self.col, line, &start_col_byte_kind, &has_iterated_past_a_space)) {
                .not_found => self.col = if (self.line + 1 >= num_of_lines) line.len else 0,
                .found => |colnr| {
                    self.col = colnr;
                    return;
                },
            }
        }
    }

    const FindForwardTargetInLineResult = union(enum) { not_found, found: usize };
    fn findForwardTargetInLine(cursor_col: usize, line: []const u8, start_col_byte_kind: *CharKind, has_iterated_past_a_space: *bool) FindForwardTargetInLineResult {
        if (start_col_byte_kind.* != .not_found) has_iterated_past_a_space.* = true;
        if (line.len == 0) return .not_found;

        var iter = code_point.Iterator{ .bytes = line };
        var i: usize = 0;
        while (iter.next()) |cp| {
            defer i += 1;
            const byte_type = getCharKind(u21, cp.code);

            if (start_col_byte_kind.* == .not_found) {
                if (i == cursor_col) start_col_byte_kind.* = byte_type;
                continue;
            }

            switch (byte_type) {
                .not_found => unreachable,
                .spacing => has_iterated_past_a_space.* = true,
                .char => if (has_iterated_past_a_space.* or start_col_byte_kind.* == .symbol) return .{ .found = i },
                .symbol => if (has_iterated_past_a_space.* or start_col_byte_kind.* == .char) return .{ .found = i },
            }
        }

        return .not_found;
    }
};

test "Cursor - basic hjkl movements" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hi\nworld\nhello\nx");
    defer ropeman.deinit();
    var c = Cursor{ .line = 0, .col = 0 };

    // moveRight()
    {
        c.moveRight(1, &ropeman);
        try eq(Cursor{ .line = 0, .col = 1 }, c);

        c.moveRight(2, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);
    }

    // moveLeft()
    {
        c.moveLeft(1);
        try eq(Cursor{ .line = 0, .col = 1 }, c);
        c.moveLeft(100);
        try eq(Cursor{ .line = 0, .col = 0 }, c);
    }

    // moveDown()
    {
        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveDown(1, &ropeman);
        try eq(Cursor{ .line = 1, .col = 2 }, c);

        c.moveDown(1, &ropeman);
        try eq(Cursor{ .line = 2, .col = 2 }, c);

        c.moveDown(100, &ropeman);
        try eq(Cursor{ .line = 3, .col = 1 }, c);
    }

    // moveUp()
    {
        c.moveUp(1, &ropeman);
        try eq(Cursor{ .line = 2, .col = 1 }, c);

        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 2, .col = 5 }, c);

        c.moveUp(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Vim Movements

test "Cursor - Vim w/W" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
    defer ropeman.deinit();
    var c = Cursor{ .line = 0, .col = 0 };

    {
        c.forwardWord(testing_allocator, 1, &ropeman);
        try eq(Cursor{ .line = 0, .col = 6 }, c);

        c.forwardWord(testing_allocator, 1, &ropeman);
        try eq(Cursor{ .line = 1, .col = 0 }, c);

        c.forwardWord(testing_allocator, 1, &ropeman);
        try eq(Cursor{ .line = 1, .col = 3 }, c);

        std.debug.print("hello?\n", .{});
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
