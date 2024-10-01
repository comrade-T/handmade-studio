const DisplayCachePool = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Buffer = @import("neo_buffer").Buffer;

const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
buf: *Buffer,

start_line: usize = 0,
end_line: usize = 0,

const InitError = error{OutOfMemory};
pub fn init(a: Allocator, buf: *Buffer) InitError!*DisplayCachePool {
    const self = try a.create(@This());
    self.* = DisplayCachePool{
        .a = a,
        .buf = buf,
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    self.a.destroy(self);
}

///////////////////////////// requestLines

const RequestLinesError = error{ OutOfMemory, EndLineOutOfBounds };
const RequestLinesResult = struct { []u21, []Display };
pub fn requestLines(self: *@This(), start: usize, end: usize) RequestLinesError!RequestLinesResult {
    if (end > self.lastLineNumber()) return RequestLinesError.EndLineOutOfBounds;
    _ = start;
    return .{ &.{}, &.{} };
}

test requestLines {
    var buf = try Buffer.create(testing_allocator, .string, "hello world");
    defer buf.destroy();

    var dcp = try DisplayCachePool.init(testing_allocator, buf);
    defer dcp.deinit();

    try shouldErr(RequestLinesError.EndLineOutOfBounds, dcp.requestLines(0, 1));
}

///////////////////////////// updateLines

// TODO:

///////////////////////////// infos

fn lastLineNumber(self: *@This()) usize {
    return self.numberOfLines() - 1;
}

fn numberOfLines(self: *@This()) usize {
    return self.buf.roperoot.weights().bols;
}

fn getWidth(self: *@This()) f32 {
    _ = self;
    unreachable;
}

fn getHeight(self: *@This()) f32 {
    _ = self;
    unreachable;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CellIndex = struct { line: usize, col: usize };
const Display = struct {
    width: f32,
    height: f32,
    variant: union(enum) {
        const Char = struct {
            font_size: f32,
            font_face: []const u8,
            color: u32,
        };
        const Image = struct {
            path: []const u8,
        };
        const Conceal = struct {
            start: CellIndex,
            end: CellIndex,
            variant: union(enum) {
                char: Char,
                image: Image,
            },
        };
        char: Char,
        image: Image,
        conceal: Conceal,
    },
};

//////////////////////////////////////////////////////////////////////////////////////////////
