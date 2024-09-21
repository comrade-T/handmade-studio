const std = @import("std");

const Buffer = @import("neo_buffer").Buffer;

const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Window

const Window = @This();

///////////////////////////// Fields

a: Allocator,

buf: *Buffer,

////////////////////////////////////////////////////////////////////////////////////////////// Tests

test {
    try eq(1, 1);
}
