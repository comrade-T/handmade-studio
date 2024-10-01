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
        char: Char,
        image: Image,
        char_conceal: Char,
        image_conceal: Image,
        being_concealed,
    },
};

//////////////////////////////////////////////////////////////////////////////////////////////

test "ArrayList swap remove" {
    var list = ArrayList(u8).init(testing_allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    try eq(true, eql(u8, &.{ 1, 2, 3 }, list.items));

    const removed_element = list.swapRemove(0);
    _ = removed_element;
    try eq(true, eql(u8, &.{ 3, 2 }, list.items));

    try list.append(4);
    try eq(true, eql(u8, &.{ 3, 2, 4 }, list.items));

    list.items[0] = 100;
    try eq(true, eql(u8, &.{ 100, 2, 4 }, list.items));

    const slice = try list.toOwnedSlice();
    defer testing_allocator.free(slice);
    std.mem.sort(u8, slice, {}, comptime std.sort.asc(u8));
    try eq(true, eql(u8, &.{ 2, 4, 100 }, slice));
}

const CustomType = struct {
    index: usize,
    ptr: *[]const u8,
    fn cmpByIndex(ctx: void, a: CustomType, b: CustomType) bool {
        return std.sort.asc(usize)(ctx, a.index, b.index);
    }
};

test "custom type sort" {
    var str_list = ArrayList([]const u8).init(testing_allocator);
    defer str_list.deinit();
    try str_list.append("one");
    try str_list.append("two");
    try str_list.append("three");

    var ct_list = ArrayList(CustomType).init(testing_allocator);
    defer ct_list.deinit();

    try ct_list.append(CustomType{ .index = 2, .ptr = &str_list.items[2] });
    try ct_list.append(CustomType{ .index = 0, .ptr = &str_list.items[0] });
    try ct_list.append(CustomType{ .index = 1, .ptr = &str_list.items[1] });

    try eqStr("three", ct_list.items[0].ptr.*);
    try eqStr("one", ct_list.items[1].ptr.*);
    try eqStr("two", ct_list.items[2].ptr.*);

    const ct_slice = try ct_list.toOwnedSlice();
    defer testing_allocator.free(ct_slice);
    std.mem.sort(CustomType, ct_slice, {}, CustomType.cmpByIndex);

    try eqStr("one", ct_slice[0].ptr.*);
    try eqStr("two", ct_slice[1].ptr.*);
    try eqStr("three", ct_slice[2].ptr.*);
}
