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
const WM = Session.WindowManager;
const CM = WM.ConnectionManager;

fn adapt(cb: anytype, ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    cb(&wm.connman);
}

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;
    const a = c.arena.allocator();

    ///////////////////////////// modes & contexts involved

    const NORMAL = "normal";
    const CYCLING = "cycling_connections";
    const PENDING = "pending_connection";

    const NORMAL_TO_CYCLING = Session.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{CYCLING} };
    const CYCLING_TO_NORMAL = Session.Callback.Contexts{ .remove = &.{CYCLING}, .add = &.{NORMAL} };

    const NORMAL_TO_PENDING = Session.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{PENDING} };
    const PENDING_TO_NORMAL = Session.Callback.Contexts{ .remove = &.{PENDING}, .add = &.{NORMAL} };

    ///////////////////////////// cycling connections

    const FuncType = *const fn (ctx: *CM) anyerror!void;
    const AdaptedCb = struct {
        func: FuncType,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try self.func(&wm.connman);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, func: FuncType, contexts: Session.Callback.Contexts) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .func = func, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self, .contexts = contexts };
        }
    };

    try c.map(NORMAL, &.{ .c, .l }, try AdaptedCb.init(a, sess, CM.enterCycleMode, NORMAL_TO_CYCLING));
    try c.map(CYCLING, &.{.escape}, try AdaptedCb.init(a, sess, CM.exitCycleMode, CYCLING_TO_NORMAL));
    try c.map(CYCLING, &.{.j}, try AdaptedCb.init(a, sess, CM.cycleToNextDownConnection, .{}));
    try c.map(CYCLING, &.{.k}, try AdaptedCb.init(a, sess, CM.cycleToNextUpConnection, .{}));
    try c.map(CYCLING, &.{.h}, try AdaptedCb.init(a, sess, CM.cycleToLeftMirroredConnection, .{}));
    try c.map(CYCLING, &.{.l}, try AdaptedCb.init(a, sess, CM.cycleToRightMirroredConnection, .{}));
    try c.map(CYCLING, &.{.n}, try AdaptedCb.init(a, sess, CM.cycleToNextConnection, .{}));
    try c.map(CYCLING, &.{.p}, try AdaptedCb.init(a, sess, CM.cycleToPreviousConnection, .{}));
    try c.map(CYCLING, &.{.backspace}, try AdaptedCb.init(a, sess, CM.hideSelectedConnection, .{}));
    try c.map(CYCLING, &.{.delete}, try AdaptedCb.init(a, sess, CM.hideSelectedConnection, .{}));
    try c.map(CYCLING, &.{.s}, try AdaptedCb.init(a, sess, CM.swapSelectedConnectionPoints, .{}));
    try c.map(CYCLING, &.{ .left_control, .z }, try AdaptedCb.init(a, sess, CM.undo, .{}));
    try c.map(CYCLING, &.{ .left_control, .left_shift, .z }, try AdaptedCb.init(a, sess, CM.redo, .{}));
    try c.map(CYCLING, &.{ .left_shift, .left_control, .z }, try AdaptedCb.init(a, sess, CM.redo, .{}));

    const SetSelectedConnectionArrowhead = struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            wm.connman.setSelectedConnectionArrowhead(self.index);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, index: usize) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .index = index, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(CYCLING, &.{ .a, .u }, try SetSelectedConnectionArrowhead.init(a, sess, 0));
    try c.map(CYCLING, &.{ .a, .i }, try SetSelectedConnectionArrowhead.init(a, sess, 1));
    try c.map(CYCLING, &.{ .a, .o }, try SetSelectedConnectionArrowhead.init(a, sess, 2));
    try c.map(CYCLING, &.{ .a, .p }, try SetSelectedConnectionArrowhead.init(a, sess, 3));
    try c.map(CYCLING, &.{ .a, .h }, try SetSelectedConnectionArrowhead.init(a, sess, 4));
    try c.map(CYCLING, &.{ .a, .j }, try SetSelectedConnectionArrowhead.init(a, sess, 5));
    try c.map(CYCLING, &.{ .a, .k }, try SetSelectedConnectionArrowhead.init(a, sess, 6));
    try c.map(CYCLING, &.{ .a, .l }, try SetSelectedConnectionArrowhead.init(a, sess, 7));
    try c.map(CYCLING, &.{ .a, .n }, try SetSelectedConnectionArrowhead.init(a, sess, 8));
    try c.map(CYCLING, &.{ .a, .m }, try SetSelectedConnectionArrowhead.init(a, sess, 9));
    try c.map(CYCLING, &.{ .a, .comma }, try SetSelectedConnectionArrowhead.init(a, sess, 10));
    try c.map(CYCLING, &.{ .a, .period }, try SetSelectedConnectionArrowhead.init(a, sess, 11));

    const AdaptedUpNDownCb = struct {
        up_func: FuncType,
        down_func: FuncType,
        sess: *Session,
        fn up(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try self.up_func(&wm.connman);
        }
        fn down(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try self.down_func(&wm.connman);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, down_func: FuncType, up_func: FuncType) !Session.UpNDownCallback {
            const self = try allocator.create(@This());
            self.* = .{ .up_func = up_func, .down_func = down_func, .sess = sess_ };
            return Session.UpNDownCallback{
                .up_f = @This().up,
                .up_ctx = self,
                .down_f = @This().down,
                .down_ctx = self,
            };
        }
    };

    try c.mapUpNDown(CYCLING, &.{.a}, try AdaptedUpNDownCb.init(a, sess, CM.startSettingArrowhead, CM.stopSettingArrowhead));

    ///////////////////////////// pending connection

    try c.map(NORMAL, &.{ .left_control, .c }, try AdaptedCb.init(a, sess, CM.startPendingConnection, NORMAL_TO_PENDING));
    try c.map(PENDING, &.{.escape}, try AdaptedCb.init(a, sess, CM.cancelPendingConnection, PENDING_TO_NORMAL));
    try c.map(PENDING, &.{.enter}, try AdaptedCb.init(a, sess, CM.confirmPendingConnection, PENDING_TO_NORMAL));

    // change target window

    const ChangeConnectionEndWinIDCb = struct {
        direction: WM.WindowRelativeDirection,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            wm.connman.switchPendingConnectionEndWindow(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, direction: WM.WindowRelativeDirection) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(PENDING, &.{ .left_control, .h }, try ChangeConnectionEndWinIDCb.init(a, sess, .left));
    try c.map(PENDING, &.{ .left_control, .l }, try ChangeConnectionEndWinIDCb.init(a, sess, .right));
    try c.map(PENDING, &.{ .left_control, .k }, try ChangeConnectionEndWinIDCb.init(a, sess, .top));
    try c.map(PENDING, &.{ .left_control, .j }, try ChangeConnectionEndWinIDCb.init(a, sess, .bottom));
    try c.map(PENDING, &.{.s}, try AdaptedCb.init(a, sess, CM.swapPendingConnectionPoints, .{}));

    const SetPendingConnectionArrowhead = struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            wm.connman.setPendingConnectionArrowhead(self.index);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, index: usize) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .index = index, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(PENDING, &.{ .a, .u }, try SetPendingConnectionArrowhead.init(a, sess, 0));
    try c.map(PENDING, &.{ .a, .i }, try SetPendingConnectionArrowhead.init(a, sess, 1));
    try c.map(PENDING, &.{ .a, .o }, try SetPendingConnectionArrowhead.init(a, sess, 2));
    try c.map(PENDING, &.{ .a, .p }, try SetPendingConnectionArrowhead.init(a, sess, 3));
    try c.map(PENDING, &.{ .a, .h }, try SetPendingConnectionArrowhead.init(a, sess, 4));
    try c.map(PENDING, &.{ .a, .j }, try SetPendingConnectionArrowhead.init(a, sess, 5));
    try c.map(PENDING, &.{ .a, .k }, try SetPendingConnectionArrowhead.init(a, sess, 6));
    try c.map(PENDING, &.{ .a, .l }, try SetPendingConnectionArrowhead.init(a, sess, 7));
    try c.map(PENDING, &.{ .a, .n }, try SetPendingConnectionArrowhead.init(a, sess, 8));
    try c.map(PENDING, &.{ .a, .m }, try SetPendingConnectionArrowhead.init(a, sess, 9));
    try c.map(PENDING, &.{ .a, .comma }, try SetPendingConnectionArrowhead.init(a, sess, 10));
    try c.map(PENDING, &.{ .a, .period }, try SetPendingConnectionArrowhead.init(a, sess, 11));

    try c.mapUpNDown(CYCLING, &.{.a}, try AdaptedUpNDownCb.init(a, sess, CM.startSettingArrowhead, CM.stopSettingArrowhead));

    // change anchor

    const ChangeConnectionAnchorCb = struct {
        const Which = enum { start, end };
        which: Which,
        anchor: CM.Connection.Anchor,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            if (wm.connman.pending_connection == null) return;
            switch (self.which) {
                .start => wm.connman.pending_connection.?.start.anchor = self.anchor,
                .end => wm.connman.pending_connection.?.end.anchor = self.anchor,
            }
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, which: Which, anchor: CM.Connection.Anchor) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .which = which, .anchor = anchor, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(PENDING, &.{ .s, .h }, try ChangeConnectionAnchorCb.init(a, sess, .start, .W));
    try c.map(PENDING, &.{ .s, .l }, try ChangeConnectionAnchorCb.init(a, sess, .start, .E));
    try c.map(PENDING, &.{ .s, .k }, try ChangeConnectionAnchorCb.init(a, sess, .start, .N));
    try c.map(PENDING, &.{ .s, .j }, try ChangeConnectionAnchorCb.init(a, sess, .start, .S));
    try c.map(PENDING, &.{ .e, .h }, try ChangeConnectionAnchorCb.init(a, sess, .end, .W));
    try c.map(PENDING, &.{ .e, .l }, try ChangeConnectionAnchorCb.init(a, sess, .end, .E));
    try c.map(PENDING, &.{ .e, .k }, try ChangeConnectionAnchorCb.init(a, sess, .end, .N));
    try c.map(PENDING, &.{ .e, .j }, try ChangeConnectionAnchorCb.init(a, sess, .end, .S));
}
