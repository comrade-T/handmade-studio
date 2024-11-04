const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const code_point = @import("code_point");

//////////////////////////////////////////////////////////////////////////////////////////////

cursors: ArrayList(Cursor),

const GetNumOfLinesCallback = *const fn (ctx: *anyopaque) usize;
const GetNocInLineCallback = *const fn (ctx: *anyopaque, linenr: usize) usize;
const GetLineCallback = *const fn (ctx: *anyopaque, a: Allocator, linenr: usize) []const u8;

const Cursor = struct {
    line: usize,
    col: usize,

    ///////////////////////////// hjkl

    pub fn moveUp(self: *@This(), by: usize, noc_cb: GetNocInLineCallback, ctx: *anyopaque) void {
        self.line -|= by;
        self.restrictCol(noc_cb, ctx);
    }

    pub fn moveDown(self: *@This(), by: usize, nol_cb: GetNumOfLinesCallback, noc_cb: GetNocInLineCallback, ctx: *anyopaque) void {
        self.line += by;
        const nol = nol_cb(ctx);
        if (self.line >= nol) self.line = nol -| 1;
        self.restrictCol(noc_cb, ctx);
    }

    pub fn moveLeft(self: *@This(), by: usize) void {
        self.col -|= by;
    }

    pub fn moveRight(self: *@This(), by: usize, noc_cb: GetNocInLineCallback, ctx: *anyopaque) void {
        self.col += by;
        self.restrictCol(noc_cb, ctx);
    }

    pub fn restrictCol(self: *@This(), noc_cb: GetNocInLineCallback, ctx: *anyopaque) void {
        const noc = noc_cb(ctx, self.line);
        if (self.col > noc) self.col = noc;
    }

    ///////////////////////////// w/W

    pub fn forwardWord(self: *@This(), a: Allocator, count: usize, nol_cb: GetNumOfLinesCallback, line_cb: GetLineCallback, ctx: *anyopaque) void {
        for (0..count) |_| self.forwardWordSingle(a, nol_cb, line_cb, ctx);
    }

    fn forwardWordSingle(self: *@This(), a: Allocator, nol_cb: GetNumOfLinesCallback, line_cb: GetLineCallback, ctx: *anyopaque) !void {
        var start_col_byte_kind = CharKind.not_found;
        var has_iterated_past_a_space = false;

        const num_of_lines = nol_cb(ctx);
        for (self.line..num_of_lines) |linenr| {
            const line = line_cb(ctx, a, linenr);
            defer a.free(line);

            self.line = linenr;
            switch (findForwardTargetInLine(self.col, line, &start_col_byte_kind, &has_iterated_past_a_space)) {
                .not_found => self.col = if (self.line + 1 >= num_of_lines) line.len else 0,
                .found => |colnr| self.col = colnr,
            }
        }
    }

    const FindForwardTargetInLineResult = union(enum) { not_found, found: usize };
    fn findForwardTargetInLine(cursor_col: usize, line: []const u8, start_col_byte_kind: *CharKind, has_iterated_past_a_space: *bool) FindForwardTargetInLineResult {
        if (line.len == 0) {
            has_iterated_past_a_space.* = true;
            return .not_found;
        }

        var iter = code_point.Iterator{ .bytes = line };
        var i: usize = 0;
        while (iter.next()) |cp| {
            defer i += 1;
            const byte_type = getCharKind(u21, cp.code);

            if (start_col_byte_kind == .not_found) {
                if (i == cursor_col) start_col_byte_kind.* = byte_type;
                continue;
            }

            switch (byte_type) {
                .not_found => unreachable,
                .spacing => has_iterated_past_a_space.* = true,
                .char => if (has_iterated_past_a_space or start_col_byte_kind == .symbol) return .{ .found = i },
                .symbol => if (has_iterated_past_a_space or start_col_byte_kind == .char) return .{ .found = i },
            }
        }

        return .not_found;
    }
};

test "Cursor - basic hjkl movements" {
    var ctx = TestingCtx{ .source = "hi\nworld\nhello\nx" };
    var c = Cursor{ .line = 0, .col = 0 };

    // moveRight()
    {
        c.moveRight(1, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 0, .col = 1 }, c);

        c.moveRight(2, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveRight(100, TestingCtx.getNumOfCharsInLine, &ctx);
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
        c.moveRight(100, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveDown(1, TestingCtx.getNumOfLines, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 1, .col = 2 }, c);

        c.moveDown(1, TestingCtx.getNumOfLines, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 2, .col = 2 }, c);

        c.moveDown(100, TestingCtx.getNumOfLines, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 3, .col = 1 }, c);
    }

    // moveUp()
    {
        c.moveUp(1, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 2, .col = 1 }, c);

        c.moveRight(100, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 2, .col = 5 }, c);

        c.moveUp(100, TestingCtx.getNumOfCharsInLine, &ctx);
        try eq(Cursor{ .line = 0, .col = 2 }, c);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Vim Movements

test "Cursor - Vim w/W" {
    var ctx = TestingCtx{ .source = "hello world\nhi venus" };
    var c = Cursor{ .line = 0, .col = 0 };

    {
        c.forwardWord(testing_allocator, 1, TestingCtx.getLine, &ctx);
        try eq(Cursor{ .line = 0, .col = 6 }, c);
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

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

const TestingCtx = struct {
    source: []const u8,

    fn getLine(ctx: *anyopaque, a: Allocator, linenr: usize) []const u8 {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        var split_iter = std.mem.split(u8, self.source, "\n");
        var i: usize = 0;
        while (split_iter.next()) |line| {
            defer i += 1;
            if (i == linenr) return a.dupe(u8, line) catch unreachable;
        }
        unreachable;
    }

    fn getNumOfCharsInLine(ctx: *anyopaque, linenr: usize) usize {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        var split_iter = std.mem.split(u8, self.source, "\n");
        var i: usize = 0;
        while (split_iter.next()) |line| {
            defer i += 1;
            if (i == linenr) return line.len;
        }
        unreachable;
    }

    fn getNumOfLines(ctx: *anyopaque) usize {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        var split_iter = std.mem.split(u8, self.source, "\n");
        var i: usize = 0;
        while (split_iter.next()) |_| {
            defer i += 1;
        }
        return i;
    }
};
