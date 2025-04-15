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

    const NORMAL_TO_CYCLING = WM.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{CYCLING} };
    const CYCLING_TO_NORMAL = WM.Callback.Contexts{ .remove = &.{CYCLING}, .add = &.{NORMAL} };

    const NORMAL_TO_PENDING = WM.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{PENDING} };
    const PENDING_TO_NORMAL = WM.Callback.Contexts{ .remove = &.{PENDING}, .add = &.{NORMAL} };

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
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, func: FuncType, contexts: WM.Callback.Contexts) !WM.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .func = func, .sess = sess_ };
            return WM.Callback{ .f = @This().f, .ctx = self, .contexts = contexts };
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
    try c.map(CYCLING, &.{.backspace}, try AdaptedCb.init(a, sess, CM.removeSelectedConnection, .{}));
    try c.map(CYCLING, &.{.delete}, try AdaptedCb.init(a, sess, CM.removeSelectedConnection, .{}));

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
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, direction: WM.WindowRelativeDirection) !WM.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .sess = sess_ };
            return WM.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(PENDING, &.{ .left_control, .h }, try ChangeConnectionEndWinIDCb.init(a, sess, .left));
    try c.map(PENDING, &.{ .left_control, .l }, try ChangeConnectionEndWinIDCb.init(a, sess, .right));
    try c.map(PENDING, &.{ .left_control, .k }, try ChangeConnectionEndWinIDCb.init(a, sess, .top));
    try c.map(PENDING, &.{ .left_control, .j }, try ChangeConnectionEndWinIDCb.init(a, sess, .bottom));

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
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, which: Which, anchor: CM.Connection.Anchor) !WM.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .which = which, .anchor = anchor, .sess = sess_ };
            return WM.Callback{ .f = @This().f, .ctx = self };
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
