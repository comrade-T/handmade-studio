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

pub const Canvas = @import("Canvas.zig");
pub const WindowManager = @import("WindowManager");
const LangHub = WindowManager.LangHub;
pub const RenderMall = WindowManager.RenderMall;
const NotificationLine = @import("NotificationLine");
const ConfirmationPrompt = @import("ConfirmationPrompt");

const AnchorPicker = @import("AnchorPicker");
const ip_ = @import("input_processor");
pub const Callback = ip_.Callback;
pub const UpNDownCallback = ip_.UpNDownCallback;
pub const MappingCouncil = ip_.MappingCouncil;
const LSPClientManager = @import("LSPClientManager");

const vim_related = @import("keymaps/vim_related.zig");
const layout_related = @import("keymaps/layout_related.zig");
const connection_manager = @import("keymaps/connection_manager.zig");
const window_picker = @import("keymaps/window_picker.zig");
const window_manager = @import("keymaps/window_manager.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,
nl: *NotificationLine,
cp: *ConfirmationPrompt,

ap: *AnchorPicker,
council: *MappingCouncil,
lspman: *LSPClientManager,

active_index: ?usize = null,
canvases: std.ArrayListUnmanaged(*Canvas) = .{},

tcbmap: std.AutoHashMapUnmanaged(TriggerCallbackKey, TriggerCallback) = .{},

pub fn mapKeys(self: *@This()) !void {
    const NORMAL = "normal";
    const c = self.council;

    try c.map(NORMAL, &.{ .space, .s, .c }, .{ .f = closeActiveCanvas, .ctx = self });
    try c.map(NORMAL, &.{ .space, .s, .n }, .{ .f = newEmptyCanvas, .ctx = self });
    try c.map(NORMAL, &.{ .space, .left_control, .s }, .{ .f = saveActiveCanvas, .ctx = self });
    try c.map(NORMAL, &.{ .space, .s, .k }, .{ .f = previousCanvas, .ctx = self });
    try c.map(NORMAL, &.{ .space, .s, .j }, .{ .f = nextCanvas, .ctx = self });

    try vim_related.mapKeys(self);
    try layout_related.mapKeys(self);
    try connection_manager.mapKeys(self);
    try window_picker.mapKeys(self);
    try window_manager.mapKeys(self);
}

pub fn newCanvas(self: *@This()) !*Canvas {
    const new_canvas = try Canvas.create(self);
    try self.canvases.append(self.a, new_canvas);
    self.active_index = self.canvases.items.len - 1;
    return new_canvas;
}

pub fn deinit(self: *@This()) void {
    for (self.canvases.items) |canvas| canvas.destroy();
    self.canvases.deinit(self.a);
    self.tcbmap.deinit(self.a);
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
    active_canvas.saveCameraInfo();
    const new_canvas = try self.newCanvas();
    try new_canvas.loadFromFile(path);
    try self.notifyActiveCanvasName();
}

pub fn saveActiveCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const active_canvas = self.getActiveCanvas() orelse return;
    if (active_canvas.path.len == 0) {
        const cb = self.tcbmap.get(.after_unnamed_save) orelse return;
        try cb.f(cb.ctx);
        return;
    }
    assert(try active_canvas.save());
}

pub fn closeActiveCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const active_canvas = self.getActiveCanvas() orelse return;
    const msg = try std.fmt.allocPrint(
        self.a,
        "Are you sure you want to close session {s}{s}? (y / n)",
        .{
            active_canvas.getName(),
            if (active_canvas.hasUnsavedChanges()) "*" else "",
        },
    );
    defer self.a.free(msg);
    try self.cp.show(msg, .{ .onConfirm = .{ .f = confirmCloseActiveCanvas, .ctx = self } });
}

fn confirmCloseActiveCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const active_canvas = self.getActiveCanvas() orelse return;

    _ = self.canvases.orderedRemove(self.active_index.?);
    active_canvas.destroy();
    self.active_index.? -|= 1;

    if (self.canvases.items.len == 0) {
        _ = try self.newCanvas();
        return;
    }
    const new_active_canvas = self.getActiveCanvas() orelse unreachable;
    new_active_canvas.restoreCameraState();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn newEmptyCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const prev_canvas = self.getActiveCanvas() orelse return;
    prev_canvas.saveCameraInfo();
    _ = try self.newCanvas();
}

fn newCanvasFromFile(self: *@This(), path: []const u8) !void {
    const new_canvas = try self.newCanvas();
    try new_canvas.loadFromFile(path);
}

fn nextCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.switchCanvas(.next);
}

fn previousCanvas(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.switchCanvas(.prev);
}

fn switchCanvas(self: *@This(), kind: enum { prev, next }) !void {
    const prev_index = self.active_index orelse return;
    const prev_canvas = self.getActiveCanvas() orelse return;
    prev_canvas.saveCameraInfo();

    switch (kind) {
        .prev => self.active_index.? -|= 1,
        .next => {
            if (self.active_index.? + 1 < self.canvases.items.len)
                self.active_index.? += 1;
        },
    }

    try self.notifyActiveCanvasName();

    const new_index = self.active_index orelse return;
    const new_canvas = self.getActiveCanvas() orelse return;
    if (new_index != prev_index) new_canvas.restoreCameraState();
}

fn notifyActiveCanvasName(self: *@This()) !void {
    const active_canvas = self.getActiveCanvas() orelse return;
    const msg = try std.fmt.allocPrint(self.a, "{s}{s} [{d}/{d}]", .{
        active_canvas.getName(),
        if (active_canvas.hasUnsavedChanges()) "*" else "",
        self.active_index.? + 1,
        self.canvases.items.len,
    });
    defer self.a.free(msg);
    try self.nl.setMessage(msg);
}

////////////////////////////////////////////////////////////////////////////////////////////// TriggerCallback

pub const TriggerCallbackKey = enum {
    after_unnamed_save,
};
pub const TriggerCallback = struct { f: CallbackFunc, ctx: *anyopaque };
pub const CallbackFunc = *const fn (ctx: *anyopaque) anyerror!void;

pub fn addCallback(self: *@This(), key: TriggerCallbackKey, cb: TriggerCallback) !void {
    try self.tcbmap.put(self.a, key, cb);
}

////////////////////////////////////////////////////////////////////////////////////////////// LSP Related

// temporary solution for LSP
pub fn postFileOpenCallback(ctx: *anyopaque, win: *WindowManager.Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    _ = self;
    _ = win;
}
