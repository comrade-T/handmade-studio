const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

cursors: ArrayList(Cursor),

const GetNumOfLinesCallback = *const fn (ctx: *anyopaque) usize;
const GetNocInLineCallback = *const fn (ctx: *anyopaque, linenr: usize) usize;
const GetLineCallback = *const fn (ctx: *anyopaque, a: Allocator, linenr: usize) []const u8;

const Cursor = struct {
    line: usize,
    col: usize,

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
};

test Cursor {
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

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

const TestingCtx = struct {
    source: []const u8,

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
