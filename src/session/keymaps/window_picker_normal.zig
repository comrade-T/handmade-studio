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
const WindowPickerNormal = WindowManager.WindowPickerNormal;
const WindowPicker = WindowPickerNormal.WindowPicker;

pub fn mapKeys(sess: *Session) !void {
    const NORMAL = "normal";
    const c = sess.council;
    const a = c.arena.allocator();

    try c.mapUpNDown(NORMAL, &.{ .space, .f }, .{
        .down_f = show,
        .up_f = hide,
        .down_ctx = sess,
        .up_ctx = sess,
    });

    /////////////////////////////

    const Cb = struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try WindowPicker.executeCallback(wm.window_picker_normal, self.index);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, index: usize) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .index = index };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .f, .y }, try Cb.init(a, sess, 0));
    try c.map(NORMAL, &.{ .space, .f, .u }, try Cb.init(a, sess, 1));
    try c.map(NORMAL, &.{ .space, .f, .i }, try Cb.init(a, sess, 2));
    try c.map(NORMAL, &.{ .space, .f, .o }, try Cb.init(a, sess, 3));
    try c.map(NORMAL, &.{ .space, .f, .p }, try Cb.init(a, sess, 4));

    try c.map(NORMAL, &.{ .space, .f, .h }, try Cb.init(a, sess, 5));
    try c.map(NORMAL, &.{ .space, .f, .j }, try Cb.init(a, sess, 6));
    try c.map(NORMAL, &.{ .space, .f, .k }, try Cb.init(a, sess, 7));
    try c.map(NORMAL, &.{ .space, .f, .l }, try Cb.init(a, sess, 8));
    try c.map(NORMAL, &.{ .space, .f, .semicolon }, try Cb.init(a, sess, 9));

    try c.map(NORMAL, &.{ .space, .f, .n }, try Cb.init(a, sess, 10));
    try c.map(NORMAL, &.{ .space, .f, .m }, try Cb.init(a, sess, 11));
    try c.map(NORMAL, &.{ .space, .f, .comma }, try Cb.init(a, sess, 12));
    try c.map(NORMAL, &.{ .space, .f, .period }, try Cb.init(a, sess, 13));
    try c.map(NORMAL, &.{ .space, .f, .slash }, try Cb.init(a, sess, 14));
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn show(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.show(&wm.window_picker_normal.picker);
}

fn hide(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    try WindowPicker.hide(&wm.window_picker_normal.picker);
}
