const TheSomething = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const Buffer = @import("Buffer");
const LangSuite = @import("LangSuite");
const LinkedList = @import("LinkedList.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
buf: *Buffer,

fn init(a: Allocator, buf: *Buffer) !TheSomething {
    const self = TheSomething{ .a = a, .buf = buf };
    return self;
}

fn deinit(self: *@This()) void {
    _ = self;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const test_source = @embedFile("fixtures/dummy.zig");

test TheSomething {
    var ls = try LangSuite.create(testing_allocator, .zig);
    try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    var buf = try Buffer.create(testing_allocator, .string, test_source);
    defer buf.destroy();

    var something = try TheSomething.init(testing_allocator, buf);
    defer something.deinit();

    {
        // TODO:
    }
}
