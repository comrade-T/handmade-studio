const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
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

    fn moveUp(self: *@This(), by: usize, cb: GetNocInLineCallback, ctx: *anyopaque) void {
        self.line -|= by;
        const noc = cb(ctx, self.line);
        if (self.col > noc) self.col = noc - 1;
    }

    fn moveDown(self: *@This(), by: usize, nol_cb: GetNumOfLinesCallback, noc_cb: GetNocInLineCallback, ctx: *anyopaque) !void {
        self.line += by;
        const nol = nol_cb(ctx);
        if (self.line >= nol) self.line = nol -| 1;
        const noc = noc_cb(ctx, self.line);
        if (self.col >= noc) self.col = noc -| 1;
    }

    fn moveLeft(self: *@This(), by: usize) void {
        self.col -|= by;
    }

    fn moveRight(self: *@This(), by: usize, cb: GetNocInLineCallback, ctx: *anyopaque) void {
        self.col += by;
        const noc = cb(ctx, self.line);
        if (self.col >= noc) self.col = noc -| 1;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////
