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

    pub fn forwardWord(self: *@This(), a: Allocator, count: usize, line_cb: GetLineCallback, ctx: *anyopaque) void {
        const line = line_cb(ctx, a, self.line);
        defer a.free(line);

        var iter = code_point.Iterator{ .bytes = line };
        var i: usize = 0;
        var current_col_byte_kind = ByteKind.not_found;
        while (iter.next()) |cp| {
            defer i += 1;
            if (i == self.col) current_col_byte_kind = getByteType(u21, cp.code);
        }

        assert(current_col_byte_kind != .not_found);
        std.debug.print("current_col_byte_kind: '{any}'\n", .{current_col_byte_kind});

        _ = count;
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

const ByteKind = enum { spacing, symbol, maybe_char, not_found };

fn getByteType(T: type, b: T) ByteKind {
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

        else => .maybe_char,
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
