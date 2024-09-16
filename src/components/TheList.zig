const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TheList = @This();

//////////////////////////////////////////////////////////////////////////////////////////////

is_visible: bool = false,

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

    const Result = struct {
        active: bool,
        text: [:0]const u8,
        font_size: i32,
        x: i32,
        y: i32,
    };

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
    self.is_visible = !self.is_visible;
}

pub fn show(self: *@This()) void {
    self.is_visible = true;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.is_visible = false;
}

pub fn prevItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.index = self.index -| 1;
}

pub fn nextItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.index += 1;
    if (self.index > self.items.len -| 1) self.index = self.items.len -| 1;
}

//////////////////////////////////////////////////////////////////////////////////////////////
