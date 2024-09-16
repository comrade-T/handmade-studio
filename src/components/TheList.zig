const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TheList = @This();

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
items: ArrayList([]const u8),

is_visible: bool = false,
index: usize = 0,
props: Props = .{},

const Props = struct {
    x: i32 = 0,
    y: i32 = 0,
    font_size: i32 = 40,
    line_height: i32 = 0,
    padding: struct { x: i32 = 0, y: i32 = 0 } = .{},
};

pub fn create(a: Allocator, props: Props) !*@This() {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .items = ArrayList([]const u8).init(a),
        .props = props,
    };
    return self;
}

pub fn fromHardCodedStrings(a: Allocator, props: Props, strings: []const []const u8) !*@This() {
    var self = try create(a, props);
    try self.items.appendSlice(strings);
    return self;
}

pub fn replaceWith(self: *@This(), replacement: []const []const u8) !void {
    self.items.deinit();
    self.items = try ArrayList([]const u8).initCapacity(self.a, replacement.len);
    try self.items.appendSlice(replacement);
}

pub fn destroy(self: *@This()) void {
    self.items.deinit();
    self.a.destroy(self);
}

pub fn dummyReplace(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.replaceWith(&.{ "dummy", "replacement" });
}

fn addItem(self: *@This(), item: []const u8) !void {
    try self.items.append(item);
}

const ListItemIterator = struct {
    list: *const TheList,
    index: usize = 0,

    const Result = struct {
        active: bool,
        text: []const u8,
        font_size: i32,
        x: i32,
        y: i32,
    };

    pub fn next(self: *@This()) ?Result {
        defer self.index += 1;

        if (self.index >= self.list.items.items.len) return null;

        const props = self.list.props;

        return Result{
            .active = self.index == self.list.index,
            .text = self.list.items.items[self.index],
            .font_size = props.font_size,
            .x = props.x + props.x,
            .y = props.y + props.y +
                (props.font_size * @as(i32, @intCast(self.index))) +
                (props.line_height * @as(i32, @intCast(self.index))),
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
    if (self.index > self.items.items.len -| 1) self.index = self.items.items.len -| 1;
}

//////////////////////////////////////////////////////////////////////////////////////////////
