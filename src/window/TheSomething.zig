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

//////////////////////////////////////////////////////////////////////////////////////////////

// TODO:

//////////////////////////////////////////////////////////////////////////////////////////////

const LinkedList = struct {
    const Value = u32;

    const Node = struct {
        value: Value,
        next: ?*Node,

        fn create(a: Allocator, value: Value) !*Node {
            const self = try a.create(Node);
            self.* = .{
                .value = value,
                .next = null,
            };
            return self;
        }
    };

    a: Allocator,
    len: usize = 0,
    head: ?*Node = null,
    tail: ?*Node = null,

    fn init(a: Allocator) LinkedList {
        return LinkedList{ .a = a };
    }

    fn deinit(self: *@This()) void {
        var current = self.head;
        while (current) |node| {
            const next = node.next;
            self.a.destroy(node);
            current = next;
        }
    }

    fn append(self: *@This(), value: Value) !void {
        const node = try Node.create(self.a, value);
        self.len += 1;
        if (self.head == null) self.head = node;
        if (self.tail != null) self.tail.?.next = node;
        self.tail = node;
    }

    fn get(self: *const @This(), index: usize) ?Value {
        if (self.len == 0 or index >= self.len) return null;
        var current = self.head;
        var i: usize = 0;
        while (current) |node| {
            defer i += 1;
            if (index == i) return node.value;
            current = node.next;
        }
        unreachable;
    }
};

test LinkedList {
    var list = LinkedList.init(testing_allocator);
    defer list.deinit();

    try eq(0, list.len);
    try eq(null, list.head);
    try eq(null, list.tail);
    try eq(null, list.get(0));
    try eq(null, list.get(100));

    try list.append(1);
    try eq(1, list.len);
    try eq(1, list.head.?.value);
    try eq(1, list.tail.?.value);
    try eq(1, list.get(0).?);
    try eq(null, list.get(1));

    try list.append(2);
    try eq(2, list.len);
    try eq(1, list.head.?.value);
    try eq(2, list.tail.?.value);
    try eq(1, list.get(0).?);
    try eq(2, list.get(1).?);
    try eq(null, list.get(2));
}
