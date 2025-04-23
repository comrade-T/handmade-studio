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
const assert = std.debug.assert;
const Session = @import("../Session.zig");
const WindowManager = Session.WindowManager;
const AlignConnectionKind = Session.WindowManager.ConnectionManager.AlignConnectionKind;
const AlignConnectionAnchor = Session.WindowManager.ConnectionManager.AlignConnectionAnchor;

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;
    const a = c.arena.allocator();

    // const CenterAtCb = struct {
    //     target: *WindowManager,
    //     fn f(ctx: *anyopaque) !void {
    //         const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    //         const center_x: f32 = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
    //         const center_y: f32 = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;
    //         self.target.centerActiveWindowAt(center_x, center_y);
    //     }
    //     pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque) !WindowManager.Callback {
    //         const self = try allocator.create(@This());
    //         const target = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    //         self.* = .{ .target = target };
    //         return WindowManager.Callback{ .f = @This().f, .ctx = self };
    //     }
    // };
    // try council.map("normal", &.{ .left_control, .c }, try CenterAtCb.init(council.arena.allocator(), wm));

    // move window
    const MoveByCb = struct {
        sess: *Session,
        x: f32,
        y: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try moveActiveWindowBy(wm, self.x, self.y);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, x: f32, y: f32) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .x = x, .y = y };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .m, .a }, try MoveByCb.init(a, sess, -100, 0));
    try c.map(NORMAL, &.{ .m, .d }, try MoveByCb.init(a, sess, 100, 0));
    try c.map(NORMAL, &.{ .m, .w }, try MoveByCb.init(a, sess, 0, -100));
    try c.map(NORMAL, &.{ .m, .s }, try MoveByCb.init(a, sess, 0, 100));

    // change window padding
    const ChangePaddingByCb = struct {
        sess: *Session,
        x_by: f32,
        y_by: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try changeActiveWindowPaddingBy(wm, self.x_by, self.y_by);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, x_by: f32, y_by: f32) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .x_by = x_by, .y_by = y_by };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .p, .a }, try ChangePaddingByCb.init(a, sess, -10, 0));
    try c.map(NORMAL, &.{ .space, .p, .d }, try ChangePaddingByCb.init(a, sess, 10, 0));
    try c.map(NORMAL, &.{ .space, .p, .w }, try ChangePaddingByCb.init(a, sess, 0, 10));
    try c.map(NORMAL, &.{ .space, .p, .s }, try ChangePaddingByCb.init(a, sess, 0, -10));

    // change window bound size
    const ChangeBoundSizeByCb = struct {
        sess: *Session,
        width_by: f32,
        height_by: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            changeActiveWindowBoundSizeBy(wm, self.width_by, self.height_by);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, width_by: f32, height_by: f32) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .width_by = width_by, .height_by = height_by };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .b, .k }, try ChangeBoundSizeByCb.init(a, sess, 0, -20));
    try c.map(NORMAL, &.{ .space, .b, .j }, try ChangeBoundSizeByCb.init(a, sess, 0, 20));
    try c.map(NORMAL, &.{ .space, .b, .h }, try ChangeBoundSizeByCb.init(a, sess, -20, 0));
    try c.map(NORMAL, &.{ .space, .b, .l }, try ChangeBoundSizeByCb.init(a, sess, 20, 0));
    try c.map(NORMAL, &.{ .space, .b }, .{ .f = toggleActiveWindowBounds, .ctx = sess, .require_clarity_afterwards = true });

    // switch active window
    const SwitchActiveWinCb = struct {
        direction: Session.WindowManager.WindowRelativeDirection,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try makeClosestWindowActive(wm, self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, direction: Session.WindowManager.WindowRelativeDirection) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .left_control, .h }, try SwitchActiveWinCb.init(a, sess, .left));
    try c.map(NORMAL, &.{ .left_control, .l }, try SwitchActiveWinCb.init(a, sess, .right));
    try c.map(NORMAL, &.{ .left_control, .k }, try SwitchActiveWinCb.init(a, sess, .top));
    try c.map(NORMAL, &.{ .left_control, .j }, try SwitchActiveWinCb.init(a, sess, .bottom));

    try c.map(NORMAL, &.{ .space, .g, .p }, .{ .f = selectFirstIncomingWindow, .ctx = sess });

    // toggle border
    try c.map(NORMAL, &.{ .left_control, .b }, .{ .f = toggleActiveWindowBorder, .ctx = sess });

    // align
    try c.map(NORMAL, &.{ .space, .a, .l }, .{ .f = alignVerticallyToFirstConnectionFrom, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .a, .h }, .{ .f = alignVerticallyToFirstConnectionTo, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .a, .j }, .{ .f = alignHorizontallyToFirstConnectionFrom, .ctx = sess });
    try c.map(NORMAL, &.{ .space, .a, .k }, .{ .f = alignHorizontallyToFirstConnectionTo, .ctx = sess });
}

////////////////////////////////////////////////////////////////////////////////////////////// Positioning

fn selectFirstIncomingWindow(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    const target = wm.getFirstVisibleIncomingWindow() orelse return;

    wm.setActiveWindow(target, true);
    target.centerCameraAt(wm.mall);
}

fn alignVerticallyToFirstConnectionFrom(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    try alignToFirstConnection(sess, .vertical, .start);
}

fn alignVerticallyToFirstConnectionTo(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    try alignToFirstConnection(sess, .vertical, .end);
}

fn alignHorizontallyToFirstConnectionFrom(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    try alignToFirstConnection(sess, .horizontal, .start);
}

fn alignHorizontallyToFirstConnectionTo(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    try alignToFirstConnection(sess, .horizontal, .end);
}

fn alignToFirstConnection(sess: *Session, kind: AlignConnectionKind, anchor: AlignConnectionAnchor) !void {
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    const active_window = wm.active_window orelse return;
    const from_win = wm.getFirstVisibleIncomingWindow() orelse return;

    const mover = if (anchor == .start) active_window else from_win;
    const target = if (anchor == .start) from_win else active_window;

    try wm.alignWindows(mover, target, kind);
}

// pub fn centerActiveWindowAt(wm: *WindowManager, center_x: f32, center_y: f32) void {
//     const active_window = wm.active_window orelse return;
//     active_window.centerAt(center_x, center_y);
// }

pub fn moveActiveWindowBy(wm: *WindowManager, x_by: f32, y_by: f32) !void {
    const active_window = wm.active_window orelse return;
    try active_window.moveBy(wm.a, wm.qtree, &wm.updating_windows_map, x_by, y_by);
    wm.cleanUpAfterAppendingToHistory(
        wm.a,
        try wm.hm.addMoveEvent(wm.a, active_window, x_by, y_by),
    );
}

pub fn toggleActiveWindowBorder(ctx: *anyopaque) !void {
    const sess = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = sess.getActiveCanvasWindowManager() orelse return;
    const active_window = wm.active_window orelse return;
    active_window.toggleBorder();
    wm.cleanUpAfterAppendingToHistory(
        wm.a,
        try wm.hm.addToggleBorderEvent(wm.a, active_window),
    );
}

pub fn changeActiveWindowPaddingBy(wm: *WindowManager, x_by: f32, y_by: f32) !void {
    const active_window = wm.active_window orelse return;
    try active_window.changePaddingBy(wm.a, wm.qtree, x_by, y_by);
    wm.cleanUpAfterAppendingToHistory(
        wm.a,
        try wm.hm.addChangePaddingEvent(wm.a, active_window, x_by, y_by),
    );
}

pub fn toggleActiveWindowBounds(ctx: *anyopaque) !void {
    const session = @as(*Session, @ptrCast(@alignCast(ctx)));
    const wm = session.getActiveCanvasWindowManager() orelse return;
    const active_window = wm.active_window orelse return;
    active_window.toggleBounds();
}

pub fn changeActiveWindowBoundSizeBy(wm: *WindowManager, width_by: f32, height_by: f32) void {
    const active_window = wm.active_window orelse return;
    active_window.changeBoundSizeBy(width_by, height_by);
}

////////////////////////////////////////////////////////////////////////////////////////////// Switch Active Window

pub fn makeClosestWindowActive(wm: *WindowManager, direction: WindowManager.WindowRelativeDirection) !void {
    const curr = wm.active_window orelse return;
    _, const may_candidate = wm.findClosestWindowToDirection(curr, direction);
    if (may_candidate) |candidate| wm.setActiveWindow(candidate, true);
}
