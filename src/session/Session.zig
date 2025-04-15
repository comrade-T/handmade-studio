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

const Session = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Canvas = @import("Canvas.zig");
pub const WindowManager = @import("WindowManager");
const LangHub = WindowManager.LangHub;
pub const RenderMall = WindowManager.RenderMall;
const NotificationLine = @import("NotificationLine");

const AnchorPicker = @import("AnchorPicker");
const ip_ = @import("input_processor");
pub const Callback = ip_.Callback;
pub const MappingCouncil = ip_.MappingCouncil;

const vim_related = @import("keymaps/vim_related.zig");
const layout_related = @import("keymaps/layout_related.zig");
const connection_manager = @import("keymaps/connection_manager.zig");
const window_picker_normal = @import("keymaps/window_picker_normal.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,
nl: *NotificationLine,

ap: *AnchorPicker,
council: *MappingCouncil,

active_index: ?usize = null,
canvases: std.ArrayListUnmanaged(*Canvas) = .{},

pub fn mapKeys(self: *@This()) !void {
    const NORMAL = "normal";
    const c = self.council;

    try c.map(NORMAL, &.{ .space, .s, .k }, .{ .f = previousCanvas, .ctx = self });
    try c.map(NORMAL, &.{ .space, .s, .j }, .{ .f = nextCanvas, .ctx = self });

    try vim_related.mapKeys(self);
    try layout_related.mapKeys(self);
    try connection_manager.mapKeys(self);
    try window_picker_normal.mapKeys(self);
}

// TODO: move all mapKeys mappings to Session level,
// not WindowManager level.

pub fn newCanvas(self: *@This()) !*Canvas {
    const new_canvas = try Canvas.create(self);
    try self.canvases.append(self.a, new_canvas);
    self.active_index = self.canvases.items.len - 1;
    return new_canvas;
}

pub fn deinit(self: *@This()) void {
    for (self.canvases.items) |canvas| canvas.destroy();
    self.canvases.deinit(self.a);
}

pub fn updateAndRender(self: *@This()) !void {
    const active_canvas = self.getActiveCanvas() orelse return;
    try active_canvas.wm.updateAndRender();
}

pub fn getActiveCanvas(self: *@This()) ?*Canvas {
    const index = self.active_index orelse {
        assert(false);
        return null;
    };
    return self.canvases.items[index];
}

pub fn getActiveCanvasWindowManager(self: *@This()) ?*WindowManager {
    const active_canvas = self.getActiveCanvas() orelse return null;
    return active_canvas.wm;
}

pub fn loadCanvasFromFile(self: *@This(), path: []const u8) !void {
    const active_canvas = self.getActiveCanvas() orelse return;
    if (active_canvas.wm.wmap.count() == 0) {
        try active_canvas.loadFromFile(path);
        try self.notifyActiveCanvasName();
        return;
    }
    const new_canvas = try self.newCanvas();
    try new_canvas.loadFromFile(path);
    try self.notifyActiveCanvasName();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn newCanvasFromFile(self: *@This(), path: []const u8) !void {
    const new_canvas = try self.newCanvas();
    try new_canvas.loadFromFile(path);
}

fn nextCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.active_index == null) return;
    if (self.active_index.? + 1 < self.canvases.items.len)
        self.active_index.? += 1;
    try self.notifyActiveCanvasName();
}

fn previousCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.active_index == null) return;
    self.active_index.? -|= 1;
    try self.notifyActiveCanvasName();
}

fn notifyActiveCanvasName(self: *@This()) !void {
    const active_canvas = self.getActiveCanvas() orelse return;
    const name = if (active_canvas.path.len == 0) "[ UNNAMED CANVAS ]" else active_canvas.path;
    const msg = try std.fmt.allocPrint(self.a, "{s} [{d}/{d}]", .{
        name,
        self.active_index.? + 1,
        self.canvases.items.len,
    });
    defer self.a.free(msg);
    try self.nl.setMessage(msg);
}
