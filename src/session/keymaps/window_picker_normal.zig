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

const NORMAL = "normal";
const MULTI_WIN = @import("window_manager.zig").MULTI_WIN;

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;
    const a = c.arena.allocator();

    /////////////////////////////

    try c.mapUpNDown(NORMAL, &.{ .space, .f }, .{
        .down_f = showNormal,
        .up_f = hideNormal,
        .down_ctx = sess,
        .up_ctx = sess,
    });

    const NormalCb = makeCb(.normal);

    try c.map(NORMAL, &.{ .space, .f, .y }, try NormalCb.init(a, sess, 0));
    try c.map(NORMAL, &.{ .space, .f, .u }, try NormalCb.init(a, sess, 1));
    try c.map(NORMAL, &.{ .space, .f, .i }, try NormalCb.init(a, sess, 2));
    try c.map(NORMAL, &.{ .space, .f, .o }, try NormalCb.init(a, sess, 3));
    try c.map(NORMAL, &.{ .space, .f, .p }, try NormalCb.init(a, sess, 4));

    try c.map(NORMAL, &.{ .space, .f, .h }, try NormalCb.init(a, sess, 5));
    try c.map(NORMAL, &.{ .space, .f, .j }, try NormalCb.init(a, sess, 6));
    try c.map(NORMAL, &.{ .space, .f, .k }, try NormalCb.init(a, sess, 7));
    try c.map(NORMAL, &.{ .space, .f, .l }, try NormalCb.init(a, sess, 8));
    try c.map(NORMAL, &.{ .space, .f, .semicolon }, try NormalCb.init(a, sess, 9));

    try c.map(NORMAL, &.{ .space, .f, .n }, try NormalCb.init(a, sess, 10));
    try c.map(NORMAL, &.{ .space, .f, .m }, try NormalCb.init(a, sess, 11));
    try c.map(NORMAL, &.{ .space, .f, .comma }, try NormalCb.init(a, sess, 12));
    try c.map(NORMAL, &.{ .space, .f, .period }, try NormalCb.init(a, sess, 13));
    try c.map(NORMAL, &.{ .space, .f, .slash }, try NormalCb.init(a, sess, 14));

    /////////////////////////////

    try c.mapUpNDown(MULTI_WIN, &.{ .space, .f }, .{
        .down_f = showMultiWin,
        .up_f = hideMultiWin,
        .down_ctx = sess,
        .up_ctx = sess,
    });

    const SelectionCb = makeCb(.selection);

    try c.map(MULTI_WIN, &.{ .space, .f, .y }, try SelectionCb.init(a, sess, 0));
    try c.map(MULTI_WIN, &.{ .space, .f, .u }, try SelectionCb.init(a, sess, 1));
    try c.map(MULTI_WIN, &.{ .space, .f, .i }, try SelectionCb.init(a, sess, 2));
    try c.map(MULTI_WIN, &.{ .space, .f, .o }, try SelectionCb.init(a, sess, 3));
    try c.map(MULTI_WIN, &.{ .space, .f, .p }, try SelectionCb.init(a, sess, 4));

    try c.map(MULTI_WIN, &.{ .space, .f, .h }, try SelectionCb.init(a, sess, 5));
    try c.map(MULTI_WIN, &.{ .space, .f, .j }, try SelectionCb.init(a, sess, 6));
    try c.map(MULTI_WIN, &.{ .space, .f, .k }, try SelectionCb.init(a, sess, 7));
    try c.map(MULTI_WIN, &.{ .space, .f, .l }, try SelectionCb.init(a, sess, 8));
    try c.map(MULTI_WIN, &.{ .space, .f, .semicolon }, try SelectionCb.init(a, sess, 9));

    try c.map(MULTI_WIN, &.{ .space, .f, .n }, try SelectionCb.init(a, sess, 10));
    try c.map(MULTI_WIN, &.{ .space, .f, .m }, try SelectionCb.init(a, sess, 11));
    try c.map(MULTI_WIN, &.{ .space, .f, .comma }, try SelectionCb.init(a, sess, 12));
    try c.map(MULTI_WIN, &.{ .space, .f, .period }, try SelectionCb.init(a, sess, 13));
    try c.map(MULTI_WIN, &.{ .space, .f, .slash }, try SelectionCb.init(a, sess, 14));
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn makeCb(comptime kind: enum { normal, selection }) type {
    return struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            switch (kind) {
                .normal => try WindowPicker.executeCallback(&wm.window_picker_normal, self.index),
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
