// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eq = std.testing.expectEqual;
const eqSlice = std.testing.expectEqualSlices;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn LinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: T,
            next: ?*Node,

            fn create(a: Allocator, value: T) !*Node {
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

        pub fn init(a: Allocator) Self {
            return Self{ .a = a };
        }

        pub fn deinit(self: *@This()) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.a.destroy(node);
                current = next;
            }
        }

        pub fn append(self: *@This(), value: T) !void {
            const node = try Node.create(self.a, value);
            self.len += 1;
            if (self.head == null) self.head = node;
            if (self.tail != null) self.tail.?.next = node;
            self.tail = node;
        }

        pub fn getNode(self: *const @This(), index: usize) ?*Node {
            if (self.len == 0 or index >= self.len) return null;
            var current = self.head;
            var i: usize = 0;
            while (current) |node| {
                defer i += 1;
                if (index == i) return node;
                current = node.next;
            }
            unreachable;
        }

        pub fn get(self: *const @This(), index: usize) ?T {
            const node = self.getNode(index) orelse return null;
            return node.value;
        }

        pub fn set(self: *@This(), index: usize, value: T) bool {
            const node = self.getNode(index) orelse return false;
            node.value = value;
            return true;
        }

        pub fn remove(self: *@This(), index: usize) bool {
            defer self.len -|= 1;

            if (index == 0) {
                const node = self.getNode(index) orelse return false;
                self.head = node.next;
                if (self.tail == node) self.tail = null;
                self.a.destroy(node);
                return true;
            }

            const prev = self.getNode(index - 1) orelse unreachable;
            const node = prev.next orelse unreachable;
            defer self.a.destroy(node);

            prev.*.next = node.next;
            if (self.head == node) self.head = prev;
            if (self.tail == node) self.tail = prev;

            return true;
        }

        pub fn appendSlice(self: *@This(), new_items: []const T) !void {
            for (new_items) |item| try self.append(item);
        }

        pub fn toOwnedSlice(self: *@This(), a: Allocator) ![]T {
            var results = try a.alloc(T, self.len);
            var current = self.head;
            var i: usize = 0;
            while (current) |node| {
                defer i += 1;
                const next = node.next;
                results[i] = node.value;
                current = next;
            }
            return results;
        }
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

test "LinkedList.append()" {
    var list = LinkedList(u32).init(testing_allocator);
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

    try eq(true, list.set(0, 100));
    try eq(2, list.len);
    try eq(100, list.head.?.value);
    try eq(2, list.tail.?.value);
    try eq(100, list.get(0).?);
    try eq(2, list.get(1).?);
    try eq(null, list.get(2));
}

test "LinkedList.remove()" {
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();

        try list.append(1);
        try eq(1, list.len);

        try eq(true, list.remove(0));
        try eq(0, list.len);
        try eq(null, list.get(0));
        try eq(.{ null, null }, .{ list.head, list.tail });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();

        try list.appendSlice(&.{ 1, 2 });
        try eq(2, list.len);

        try eq(true, list.remove(0));
        try eq(1, list.len);
        try list.appendSlice(&.{2});
        try eq(.{ 2, 2 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();

        try list.appendSlice(&.{ 1, 2 });
        try eq(2, list.len);

        try eq(true, list.remove(1));
        try eq(1, list.len);
        try eqSlice(u32, &.{1}, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(null, list.get(1));
        try eq(.{ 1, 1 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();

        try list.appendSlice(&.{ 1, 2, 3 });
        try eq(3, list.len);
        try eqSlice(u32, &.{ 1, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));

        try eq(true, list.remove(1));
        try eq(2, list.len);
        try eqSlice(u32, &.{ 1, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
        try eq(null, list.get(2));
    }
}
