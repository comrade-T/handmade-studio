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
const wm_ = @import("window_manager.zig");
const MULTI_WIN = wm_.MULTI_WIN;
const WMAdapted = wm_.AdaptedCb;
const layout_related = @import("layout_related.zig");

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;
    const a = c.arena.allocator();

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .f, .backslash }, .{ .f = layout_related.centerCameraAtActiveWindow, .ctx = sess });
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .f, .q }, .{ .f = layout_related.centerCameraAtActiveWindow, .ctx = sess });
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .f, .q }, .{ .f = layout_related.centerCameraAtActiveWindow, .ctx = sess });
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .f, .e }, try WMAdapted.init(a, sess, WindowManager.toggleActiveWindowFromSelection, wm_.NORMAL_TO_MULTI_WIN));

    const AdaptedUpNDownCb = struct {
        kind: CbType,
        sess: *Session,
        fn up(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try WindowPicker.hide(getPicker(wm, self.kind));
        }
        fn down(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try WindowPicker.show(getPicker(wm, self.kind));
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, kind: CbType) !Session.UpNDownCallback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .kind = kind };
            return Session.UpNDownCallback{ .up_f = @This().up, .up_ctx = self, .down_f = @This().down, .down_ctx = self };
        }
    };

    try c.mapUpNDown(NORMAL, &.{ .space, .f }, try AdaptedUpNDownCb.init(a, sess, .normal_no_center_cam));
    try mapTargetKeys(sess, NORMAL, .normal_no_center_cam, &.{ .space, .f });

    try c.mapUpNDown(NORMAL, &.{ .space, .left_shift, .f }, try AdaptedUpNDownCb.init(a, sess, .normal));
    try mapTargetKeys(sess, NORMAL, .normal, &.{ .space, .left_shift, .f });

    try c.mapUpNDown(MULTI_WIN, &.{ .space, .f }, try AdaptedUpNDownCb.init(a, sess, .selection));
    try mapTargetKeys(sess, MULTI_WIN, .selection, &.{ .space, .f });

    try c.mapUpNDown(MULTI_WIN, &.{ .space, .v }, try AdaptedUpNDownCb.init(a, sess, .vertical_justify));
    try mapTargetKeys(sess, MULTI_WIN, .vertical_justify, &.{ .space, .v });
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

const CbType = enum { normal, normal_no_center_cam, selection, vertical_justify };
fn makeCb(comptime kind: CbType) type {
    return struct {
        sess: *Session,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try WindowPicker.executeCallback(getPicker(wm, kind), self.index);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, index: usize) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .index = index };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
}

fn getPicker(wm: *WindowManager, kind: CbType) *WindowPicker {
    return switch (kind) {
        .normal => &wm.window_picker_normal,
        .normal_no_center_cam => &wm.window_picker_normal_no_center_cam,
        .selection => &wm.selection_window_picker,
        .vertical_justify => &wm.vertical_justify_target_picker,
    };
}
