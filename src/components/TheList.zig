const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const TheList = @This();

//////////////////////////////////////////////////////////////////////////////////////////////

visible: bool = false,

items: [][:0]const u8,
index: usize = 0,

x: i32 = 0,
y: i32 = 0,
font_size: i32 = 40,
line_height: i32 = 0,
padding: struct {
    x: i32 = 0,
    y: i32 = 0,
} = .{},

const ListItemIterator = struct {
    list: *const TheList,
    index: usize = 0,

    const Result = struct { x: i32, y: i32, text: [:0]const u8, font_size: i32, active: bool };
    pub fn next(self: *@This()) ?Result {
        defer self.index += 1;
        if (self.index >= self.list.items.len) return null;
        return Result{
            .active = self.index == self.list.index,
            .text = self.list.items[self.index],
            .font_size = self.list.font_size,
            .x = self.list.x + self.list.padding.x,
            .y = self.list.y + self.list.padding.y +
                (self.list.font_size * @as(i32, @intCast(self.index))) +
                (self.list.line_height * @as(i32, @intCast(self.index))),
        };
    }
};

pub fn iter(self: *const @This()) ListItemIterator {
    return ListItemIterator{ .list = self };
}

pub fn toggle(self: *@This()) void {
    self.visible = !self.visible;
}

pub fn prevItem(self: *@This()) void {
    self.index = self.index -| 1;
}

pub fn nextItem(self: *@This()) void {
    self.index += 1;
    if (self.index > self.items.len -| 1) self.index = self.items.len -| 1;
}

//////////////////////////////////////////////////////////////////////////////////////////////
