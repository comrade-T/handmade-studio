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
const Session = @import("../Session.zig");
const WindowManager = Session.WindowManager;
const WindowPicker = WindowManager.WindowPicker;
const Key = Session.ip_.Key;

const NORMAL = "normal";
const MULTI_WIN = @import("window_manager.zig").MULTI_WIN;
const layout_related = @import("layout_related.zig");

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;

    try c.mapUpNDown(NORMAL, &.{ .space, .left_shift, .f }, .{
        .down_f = showNormal,
        .up_f = hideNormal,
        .down_ctx = sess,
        .up_ctx = sess,
    });
    try c.mapUpNDown(NORMAL, &.{ .space, .f }, .{
        .down_f = showNormalNoCenterCam,
        .up_f = hideNormalNoCenterCam,
        .down_ctx = sess,
        .up_ctx = sess,
    });
    try c.map(NORMAL, &.{ .space, .f, .backslash }, .{ .f = layout_related.centerCameraAtActiveWindow, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .f, .q }, .{ .f = layout_related.centerCameraAtActiveWindow, .ctx = sess });

    try mapTargetKeys(sess, NORMAL, .normal_no_center_cam, &.{ .space, .f });
    try mapTargetKeys(sess, NORMAL, .normal, &.{ .space, .left_shift, .f });

    /////////////////////////////

    try c.mapUpNDown(MULTI_WIN, &.{ .space, .f }, .{
        .down_f = showMultiWin,
        .up_f = hideMultiWin,
        .down_ctx = sess,
        .up_ctx = sess,
    });

    try mapTargetKeys(sess, MULTI_WIN, .selection, &.{ .space, .f });
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn mapTargetKeys(sess: *Session, mode: []const u8, comptime kind: CbType, prefix: []const Key) !void {
    const suffixes = [_]Key{
        .y,     .u,     .i,     .o,      .p,
        .h,     .j,     .k,     .l,      .semicolon,
        .n,     .m,     .comma, .period, .slash,
        .seven, .eight, .nine,  .zero,   .minus,
    };

    const a = sess.council.arena.allocator();
    for (suffixes, 0..) |suffix, i| {
        var keys = try a.alloc(Key, prefix.len + 1);
        for (prefix, 0..) |p, j| keys[j] = p;
        keys[prefix.len] = suffix;

        const Cb = makeCb(kind);
        try sess.council.map(mode, keys, try Cb.init(a, sess, i));
    }
}

const CbType = enum { normal, normal_no_center_cam, selection };
fn makeCb(comptime kind: CbType) type {
    return struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            switch (kind) {
                .normal => try WindowPicker.executeCallback(&wm.window_picker_normal, self.index),
                .normal_no_center_cam => try WindowPicker.executeCallback(&wm.window_picker_normal_no_center_cam, self.index),
                .selection => try WindowPicker.executeCallback(&wm.selection_window_picker, self.index),
            }
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, index: usize) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .index = index };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
}

/////////////////////////////

fn showNormal(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.show(&wm.window_picker_normal);
}

fn hideNormal(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.hide(&wm.window_picker_normal);
}

/////////////////////////////

fn showNormalNoCenterCam(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.show(&wm.window_picker_normal_no_center_cam);
}

fn hideNormalNoCenterCam(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.hide(&wm.window_picker_normal_no_center_cam);
}

/////////////////////////////

fn showMultiWin(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.show(&wm.selection_window_picker);
}

fn hideMultiWin(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.hide(&wm.selection_window_picker);
}
