const std = @import("std");
const fs = @import("../fs.zig");
const ip = @import("input_processor");
const Key = ip.Key;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Self = @This();

exa: Allocator,
arena: std.heap.ArenaAllocator,

is_visible: bool = false,

short_paths: [][]const u8,
history: ArrayList(ArrayList(u8)),
index: usize,

pub fn new(external_allocator: Allocator) !*@This() {
    var self = try external_allocator.create(@This());
    self.exa = external_allocator;
    self.arena = std.heap.ArenaAllocator.init(self.exa);
    self.short_paths = fs.getFileNamesRelativeToCwd(self.arena.allocator(), ".");
    self.history = ArrayList(ArrayList(u8)).init(self.exa);
    self.index = 0;
    return self;
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    for (self.history.items) |path| path.deinit();
    self.history.deinit();
    self.exa.destroy(self);
}

pub fn registerKeyMaps(self: *@This(), council: *ip.MappingCouncil) !void {
    const Cb = struct {
        fn toggle(target_: *anyopaque) !void {
            const target = @as(*Self, @ptrCast(@alignCast(target_)));
            target.toggle();
        }
        fn moveUp(target_: *anyopaque) !void {
            const target = @as(*Self, @ptrCast(@alignCast(target_)));
            target.moveUp();
        }
        fn moveDown(target_: *anyopaque) !void {
            const target = @as(*Self, @ptrCast(@alignCast(target_)));
            target.moveDown();
        }
    };

    try council.map("file_navigator", &[_]Key{.q}, .{ .f = Cb.toggle, .ctx = self });
    try council.map("file_navigator", &[_]Key{.k}, .{ .f = Cb.moveUp, .ctx = self });
    try council.map("file_navigator", &[_]Key{.j}, .{ .f = Cb.moveDown, .ctx = self });
}

pub fn toggle(self: *@This()) void {
    self.is_visible = !self.is_visible;
}

pub fn getCurrentRelativePath(self: *@This()) !ArrayList(u8) {
    var result = std.ArrayList(u8).init(self.exa);
    if (self.history.items.len == 0) {
        try result.appendSlice(".");
    } else {
        const last_history = self.history.items[self.history.items.len - 1];
        try result.appendSlice(last_history.items);
    }
    return result;
}

pub fn backwards(self: *@This()) !void {
    if (self.history.items.len == 0) return;
    const last_history = self.history.pop();
    last_history.deinit();

    const target_path = try self.getCurrentRelativePath();
    defer target_path.deinit();

    self.arena.deinit();
    self.arena = std.heap.ArenaAllocator.init(self.exa);

    const new_short_paths = fs.getFileNamesRelativeToCwd(self.arena.allocator(), target_path.items);
    self.short_paths = new_short_paths;
    self.index = 0;
}

pub fn forward(self: *@This()) !?ArrayList(u8) {
    const current_relative_path = try self.getCurrentRelativePath();
    defer current_relative_path.deinit();
    const current_short_path = self.short_paths[self.index];

    var new_relative_path = std.ArrayList(u8).init(self.exa);
    if (self.history.items.len > 0) try new_relative_path.appendSlice(current_relative_path.items);
    try new_relative_path.appendSlice(current_short_path);

    if (std.mem.endsWith(u8, current_short_path, "/")) {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.exa);

        const new_short_paths = fs.getFileNamesRelativeToCwd(self.arena.allocator(), new_relative_path.items);
        self.short_paths = new_short_paths;
        self.index = 0;

        try self.history.append(new_relative_path);
        return null;
    }

    return new_relative_path;
}

pub fn moveUp(self: *@This()) void {
    self.index = self.index -| 1;
}

pub fn moveDown(self: *@This()) void {
    if (self.index + 1 < self.short_paths.len) self.index = self.index + 1;
}
