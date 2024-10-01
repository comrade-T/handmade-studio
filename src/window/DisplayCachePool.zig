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
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
buf: *Buffer,

fn init(a: Allocator, buf: *Buffer) !*DisplayCachePool {
    const self = try a.create(@This());
    self.* = DisplayCachePool{
        .a = a,
        .buf = buf,
    };
    return self;
}

fn deinit(self: *@This()) void {
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
    var buf = try Buffer.create(testing_allocator, .string, "hello world");
    defer buf.destroy();

    var dcp = try DisplayCachePool.init(testing_allocator, buf);
    defer dcp.deinit();
}
