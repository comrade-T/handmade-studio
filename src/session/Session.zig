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
pub const ip_ = @import("input_processor");
pub const Callback = ip_.Callback;
pub const UpNDownCallback = ip_.UpNDownCallback;
pub const MappingCouncil = ip_.MappingCouncil;
const LSPClientManager = @import("LSPClientManager");

pub const StrategicMap = @import("StrategicMap.zig");

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

yank_origin: ?*WindowManager = null,
yanked_and_pasted: bool = false,

experimental_minimap: StrategicMap = .{
    .padding = .{
        .left = .{ .min = 75, .quant = 25 },
        .right = .{ .min = 75, .quant = 25 },
        .top = .{ .min = 75, .quant = 25 },
        .bottom = .{ .min = 75, .quant = 25 },
    },
},

pub fn mapKeys(sess: *@This()) !void {
    const NORMAL = "normal";
    const c = sess.council;
    const a = sess.council.arena.allocator();

    try c.map(NORMAL, &.{ .space, .s, .c }, .{ .f = closeActiveCanvas, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .s, .n }, .{ .f = newEmptyCanvas, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .left_control, .s }, .{ .f = saveActiveCanvas, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .s, .k }, .{ .f = previousCanvas, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .s, .j }, .{ .f = nextCanvas, .ctx = sess });

    try vim_related.mapKeys(sess);
    try layout_related.mapKeys(sess);
    try connection_manager.mapKeys(sess);
    try window_picker.mapKeys(sess);
    try window_manager.mapKeys(sess);

    // Marks
    const Cb = struct {
        sess: *Session,
        opts: CbOpts,

        const CbOpts = union(enum) {
            save: struct { []const u8, u32 },
            jump: u32,
        };

        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const canvas = self.sess.getActiveCanvas() orelse return;

            switch (self.opts) {
                .save => |info| canvas.marksman.saveMark(self.sess, info[0], info[1]),
                .jump => |idx| canvas.marksman.jumpToMark(self.sess, idx),
            }
        }

        pub fn init(allocator: Allocator, sess_: *Session, opts: CbOpts) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .opts = opts };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };

    // StrategicMap
    try c.map(NORMAL, &.{ .apostrophe, .left_shift, .a }, .{ .f = decreaseExperimentalMinimapRadius, .ctx = sess });
    try c.map(NORMAL, &.{ .apostrophe, .left_shift, .d }, .{ .f = increaseExperimentalMinimapRadius, .ctx = sess });

    try c.mapUpNDown(NORMAL, &.{.apostrophe}, .{
        .down_f = showExperimentalMinimap,
        .down_ctx = sess,
        .up_f = hideExperimentalMinimap,
        .up_ctx = sess,
    });

    try c.map(NORMAL, &.{ .apostrophe, .j }, .{ .f = jumpToBeforeJumpMark, .ctx = sess });

    try c.map(NORMAL, &.{ .apostrophe, .q }, try Cb.init(a, sess, .{ .jump = 0 }));
    try c.map(NORMAL, &.{ .apostrophe, .w }, try Cb.init(a, sess, .{ .jump = 1 }));
    try c.map(NORMAL, &.{ .apostrophe, .e }, try Cb.init(a, sess, .{ .jump = 2 }));
    try c.map(NORMAL, &.{ .apostrophe, .r }, try Cb.init(a, sess, .{ .jump = 3 }));
    try c.map(NORMAL, &.{ .apostrophe, .t }, try Cb.init(a, sess, .{ .jump = 4 }));
    try c.map(NORMAL, &.{ .apostrophe, .a }, try Cb.init(a, sess, .{ .jump = 5 }));
    try c.map(NORMAL, &.{ .apostrophe, .s }, try Cb.init(a, sess, .{ .jump = 6 }));
    try c.map(NORMAL, &.{ .apostrophe, .d }, try Cb.init(a, sess, .{ .jump = 7 }));
    try c.map(NORMAL, &.{ .apostrophe, .f }, try Cb.init(a, sess, .{ .jump = 8 }));
    try c.map(NORMAL, &.{ .apostrophe, .g }, try Cb.init(a, sess, .{ .jump = 9 }));
    try c.map(NORMAL, &.{ .apostrophe, .z }, try Cb.init(a, sess, .{ .jump = 10 }));
    try c.map(NORMAL, &.{ .apostrophe, .x }, try Cb.init(a, sess, .{ .jump = 11 }));
    try c.map(NORMAL, &.{ .apostrophe, .c }, try Cb.init(a, sess, .{ .jump = 12 }));
    try c.map(NORMAL, &.{ .apostrophe, .v }, try Cb.init(a, sess, .{ .jump = 13 }));
    try c.map(NORMAL, &.{ .apostrophe, .b }, try Cb.init(a, sess, .{ .jump = 14 }));

    try c.map(NORMAL, &.{ .space, .m, .q }, try Cb.init(a, sess, .{ .save = .{ "q", 0 } }));
    try c.map(NORMAL, &.{ .space, .m, .w }, try Cb.init(a, sess, .{ .save = .{ "w", 1 } }));
    try c.map(NORMAL, &.{ .space, .m, .e }, try Cb.init(a, sess, .{ .save = .{ "e", 2 } }));
    try c.map(NORMAL, &.{ .space, .m, .r }, try Cb.init(a, sess, .{ .save = .{ "r", 3 } }));
    try c.map(NORMAL, &.{ .space, .m, .t }, try Cb.init(a, sess, .{ .save = .{ "t", 4 } }));
    try c.map(NORMAL, &.{ .space, .m, .a }, try Cb.init(a, sess, .{ .save = .{ "a", 5 } }));
    try c.map(NORMAL, &.{ .space, .m, .s }, try Cb.init(a, sess, .{ .save = .{ "s", 6 } }));
    try c.map(NORMAL, &.{ .space, .m, .d }, try Cb.init(a, sess, .{ .save = .{ "d", 7 } }));
    try c.map(NORMAL, &.{ .space, .m, .f }, try Cb.init(a, sess, .{ .save = .{ "f", 8 } }));
    try c.map(NORMAL, &.{ .space, .m, .g }, try Cb.init(a, sess, .{ .save = .{ "g", 9 } }));
    try c.map(NORMAL, &.{ .space, .m, .z }, try Cb.init(a, sess, .{ .save = .{ "z", 10 } }));
    try c.map(NORMAL, &.{ .space, .m, .x }, try Cb.init(a, sess, .{ .save = .{ "x", 11 } }));
    try c.map(NORMAL, &.{ .space, .m, .c }, try Cb.init(a, sess, .{ .save = .{ "c", 12 } }));
    try c.map(NORMAL, &.{ .space, .m, .v }, try Cb.init(a, sess, .{ .save = .{ "v", 13 } }));
    try c.map(NORMAL, &.{ .space, .m, .b }, try Cb.init(a, sess, .{ .save = .{ "b", 14 } }));
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

pub fn getActiveCanvas(self: *const @This()) ?*Canvas {
    const index = self.active_index orelse {
        assert(false);
        return null;
    };
    return self.canvases.items[index];
}

pub fn getActiveCanvasWindowManager(self: *const @This()) ?*WindowManager {
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

    for (self.canvases.items, 0..) |canvas, i| {
        if (std.mem.eql(u8, canvas.path, path)) {
            try self.switchCanvas(.{ .set = i });
            return;
        }
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

    if (self.yank_origin) |yank_origin| {
        if (active_canvas.wm == yank_origin) self.yank_origin = null;
    }

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

fn switchCanvas(self: *@This(), kind: union(enum) { prev, next, set: usize }) !void {
    const prev_index = self.active_index orelse return;
    const prev_canvas = self.getActiveCanvas() orelse return;
    prev_canvas.saveCameraInfo();

    switch (kind) {
        .set => |set_to| self.active_index.? = set_to,
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

////////////////////////////////////////////////////////////////////////////////////////////// Yank Selected Windows

pub fn nop(ctx: *anyopaque) !void {
    _ = ctx;
}

pub fn moveByAfterMaybePaste(self: *@This(), x_by: f32, y_by: f32) !void {
    if (!self.yanked_and_pasted) {
        const wm = self.getActiveCanvasWindowManager() orelse return;
        try wm.yanker.yankSelectedWindows();

        const duped_windows = try wm.paste(self.a, wm, .in_place);
        defer self.a.free(duped_windows);

        try wm.clearSelection();
        try wm.addWindowsToSelection(duped_windows);

        self.yanked_and_pasted = true;
    }

    const wm = self.getActiveCanvasWindowManager() orelse return;
    try layout_related.moveActiveWindowBy(wm, x_by, y_by);
}

pub fn stopYankingDown(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.yanked_and_pasted = false;
}

/////////////////////////////

pub fn yankSelectedWindows(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const wm = self.getActiveCanvasWindowManager() orelse return;
    try wm.yanker.yankSelectedWindows();
    try wm.clearSelection();

    const msg = try std.fmt.allocPrint(self.a, "Yanked {d} Windows", .{wm.yanker.map.count()});
    defer self.a.free(msg);
    try self.nl.setMessage(msg);

    self.yank_origin = wm;
}

pub fn pasteAtScreenCenter(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const wm = self.getActiveCanvasWindowManager() orelse return;
    const origin = self.yank_origin orelse return;
    const duped_windows = try wm.paste(self.a, origin, .screen_center);
    defer self.a.free(duped_windows);
}

////////////////////////////////////////////////////////////////////////////////////////////// LSP Related

// temporary solution for LSP
pub fn postFileOpenCallback(ctx: *anyopaque, win: *WindowManager.Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    _ = self;
    _ = win;
}

////////////////////////////////////////////////////////////////////////////////////////////// Experimental Mini Map Prototype

fn showExperimentalMinimap(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.experimental_minimap.isVisible()) return;

    const canvas = self.getActiveCanvas() orelse return;
    canvas.marksman.saveBeforeJumpMark(self);

    self.experimental_minimap.show();
}

fn hideExperimentalMinimap(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.experimental_minimap.hide();
}

fn jumpToBeforeJumpMark(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const canvas = self.getActiveCanvas() orelse return;
    canvas.marksman.jumpToBeforeJumpMark(self);
}

fn increaseExperimentalMinimapRadius(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.experimental_minimap.incrementCircleRadiusBy(1);
}

fn decreaseExperimentalMinimapRadius(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.experimental_minimap.incrementCircleRadiusBy(-1);
}
