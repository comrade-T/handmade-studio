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
const assert = std.debug.assert;
const eq = std.testing.expectEqual;
const eqSlice = std.testing.expectEqualSlices;
const shouldErr = std.testing.expectError;

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
            if (index == 0) return self.removeNodeAt0thIndex();

            const prev = self.getNode(index - 1) orelse unreachable;
            self.removeNodeUsingPrev(prev);
            return true;
        }

        fn removeNodeAt0thIndex(self: *@This()) bool {
            defer self.len -|= 1;
            const node = self.getNode(0) orelse return false;
            self.head = node.next;
            if (self.tail == node) self.tail = null;
            self.a.destroy(node);
            return true;
        }

        fn removeNodeUsingPrev(self: *@This(), prev: *Node) void {
            defer self.len -|= 1;
            assert(prev.next != null);
            const node = prev.next orelse unreachable;
            defer self.a.destroy(node);

            prev.*.next = node.next;
            if (self.head == node) self.head = prev;
            if (self.tail == node) self.tail = prev;
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

        pub fn insertAfter(self: *@This(), i: usize, new_item: T) !bool {
            const prev = self.getNode(i) orelse return false;
            try self.insertAfterNode(prev, new_item);
            return true;
        }

        pub fn insertAfterNode(self: *@This(), prev: *Node, new_item: T) !void {
            const node = try Node.create(self.a, new_item);
            node.next = prev.next;
            prev.next = node;
            self.len += 1;
            if (self.tail == prev) self.tail = node;
        }

        pub fn prepend(self: *@This(), new_item: T) !void {
            defer self.len += 1;
            const node = try Node.create(self.a, new_item);
            node.next = self.head;
            self.head = node;
            if (self.tail == null) self.tail = node;
        }

        pub fn prependSlice(self: *@This(), new_items: []const T) !void {
            var i = new_items.len;
            while (i > 0) {
                i -= 1;
                try self.prepend(new_items[i]);
            }
        }

        pub fn replaceRange(self: *@This(), start: usize, len: usize, new_items: []const T) !void {
            assert(start + len <= self.len);
            if (len == 0 and new_items.len == 0) return;
            if (start + len > self.len) return;

            var removal_anchor: ?*Node = null;
            var removal_anchor_type: enum { none, head, body } = .none;
            const num_to_remove: i64 = @as(i64, @intCast(len)) - @as(i64, @intCast(new_items.len));
            const num_to_replace = if (num_to_remove <= 0) @min(len, new_items.len) else 0;

            var num_replaced: usize = 0;
            var num_inserted: usize = 0;

            var current: ?*Node = self.head;
            var prev: ?*Node = null;
            var i: usize = 0;
            while (current) |node| {
                defer i += 1;
                defer current = node.next;
                defer prev = node;

                // not there yet
                if (i < start) continue;

                // in overwrite range
                if (i < start + num_to_replace) {
                    node.value = new_items[i - start];
                    num_replaced += 1;
                    continue;
                }

                // to be removed
                if (i < start + len) {
                    if (removal_anchor_type == .none) {
                        if (prev == null) {
                            assert(i == 0);
                            removal_anchor_type = .head;
                            continue;
                        }
                        removal_anchor = prev;
                        removal_anchor_type = .body;
                    }
                    continue;
                }

                // to be inserted

                if (i == 0) {
                    try self.prependSlice(new_items);
                    num_inserted += new_items.len;
                    break;
                }

                if (i - start >= new_items.len) break;

                assert(prev != null);
                var target = prev;
                for (i - start..new_items.len) |j| {
                    assert(target != null);
                    try self.insertAfterNode(target orelse break, new_items[j]);
                    num_inserted += 1;
                    target = target.?.next;
                }
                break;
            }

            if (num_replaced + num_inserted < new_items.len) {
                const slice = new_items[num_replaced + num_inserted .. new_items.len];
                try self.appendSlice(slice);
                num_inserted += slice.len;
            }
            assert(num_replaced + num_inserted == new_items.len);

            if (num_to_remove > 0) {
                switch (removal_anchor_type) {
                    .none => {},
                    .head => {
                        for (0..@intCast(num_to_remove)) |_| {
                            const is_removed = self.removeNodeAt0thIndex();
                            assert(is_removed);
                        }
                    },
                    .body => {
                        assert(removal_anchor != null);
                        for (0..@intCast(num_to_remove)) |_| {
                            self.removeNodeUsingPrev(removal_anchor.?);
                        }
                    },
                }
            }
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

test "LinkedList.insertAfter()" {
    var list = LinkedList(u32).init(testing_allocator);
    defer list.deinit();

    try list.appendSlice(&.{ 1, 2, 3 });
    try eqSlice(u32, &.{ 1, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));

    try eq(true, try list.insertAfter(0, 100));
    try eqSlice(u32, &.{ 1, 100, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
    try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });

    try eq(true, try list.insertAfter(2, 200));
    try eqSlice(u32, &.{ 1, 100, 2, 200, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
    try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });

    try eq(true, try list.insertAfter(4, 300));
    try eqSlice(u32, &.{ 1, 100, 2, 200, 3, 300 }, try list.toOwnedSlice(idc_if_it_leaks));
    try eq(.{ 1, 300 }, .{ list.head.?.value, list.tail.?.value });

    try eq(true, try list.insertAfter(5, 1000));
    try eqSlice(u32, &.{ 1, 100, 2, 200, 3, 300, 1000 }, try list.toOwnedSlice(idc_if_it_leaks));
    try eq(.{ 1, 1000 }, .{ list.head.?.value, list.tail.?.value });
}

test "LinkedList.prepend() & LinkedList.prependSlice()" {
    var list = LinkedList(u32).init(testing_allocator);
    defer list.deinit();

    try list.appendSlice(&.{ 1, 2, 3 });
    try list.prepend(0);
    try eqSlice(u32, &.{ 0, 1, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
    try eq(.{ 0, 3 }, .{ list.head.?.value, list.tail.?.value });
}

test "LinkedList.replaceRange()" {

    ///////////////////////////// insert only

    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 0, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 100, 200, 300, 1, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 100, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(1, 0, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 100, 200, 300, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(2, 0, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 2, 100, 200, 300, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(3, 0, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 2, 3, 100, 200, 300 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 300 }, .{ list.head.?.value, list.tail.?.value });
    }

    ///////////////////////////// remove only

    // remove at 0th index
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 0, &.{});
        try eqSlice(u32, &.{ 1, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 1, &.{});
        try eqSlice(u32, &.{ 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 2, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 2, &.{});
        try eqSlice(u32, &.{3}, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 3, 3 }, .{ list.head.?.value, list.tail.?.value });
    }

    // remove at 1st index
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(1, 1, &.{});
        try eqSlice(u32, &.{ 1, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(1, 2, &.{});
        try eqSlice(u32, &.{1}, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 1 }, .{ list.head.?.value, list.tail.?.value });
    }

    // remove at 2nd index
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(2, 1, &.{});
        try eqSlice(u32, &.{ 1, 2 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 2 }, .{ list.head.?.value, list.tail.?.value });
    }

    ///////////////////////////// replace and insert

    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 1, &.{100});
        try eqSlice(u32, &.{ 100, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 100, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 1, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 100, 200, 300, 2, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 100, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(0, 3, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 100, 200, 300 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 100, 300 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(1, 1, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 100, 200, 300, 3 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 3 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(1, 2, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 100, 200, 300 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 300 }, .{ list.head.?.value, list.tail.?.value });
    }
    {
        var list = LinkedList(u32).init(testing_allocator);
        defer list.deinit();
        try list.appendSlice(&.{ 1, 2, 3 });

        try list.replaceRange(2, 1, &.{ 100, 200, 300 });
        try eqSlice(u32, &.{ 1, 2, 100, 200, 300 }, try list.toOwnedSlice(idc_if_it_leaks));
        try eq(.{ 1, 300 }, .{ list.head.?.value, list.tail.?.value });
    }
}
