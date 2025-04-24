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
const Callback = Session.Callback;

const NORMAL = "normal";
pub const MULTI_WIN = "MULTI_WIN";

const MULTI_WIN_TO_NORMAL = Callback.Contexts{ .remove = &.{MULTI_WIN}, .add = &.{NORMAL} };
const NORMAL_TO_MULTI_WIN = Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{MULTI_WIN} };

pub fn mapKeys(sess: *Session) !void {
    const c = sess.council;
    const a = c.arena.allocator();

    const FuncType = *const fn (ctx: *WindowManager) anyerror!void;
    const AdaptedCb = struct {
        func: FuncType,
        sess: *Session,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;
            try self.func(wm);
        }
        pub fn init(allocator: std.mem.Allocator, sess_: *Session, func: FuncType, contexts: Session.Callback.Contexts) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .func = func, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self, .contexts = contexts };
        }
    };

    ///////////////////////////// Close Windows

    try c.map(NORMAL, &.{ .left_control, .q }, try AdaptedCb.init(a, sess, WindowManager.closeActiveWindow, .{}));

    try c.map(NORMAL, &.{ .left_control, .left_shift, .left_alt, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));
    try c.map(NORMAL, &.{ .left_control, .left_alt, .left_shift, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));
    try c.map(NORMAL, &.{ .left_shift, .left_control, .left_alt, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));
    try c.map(NORMAL, &.{ .left_shift, .left_alt, .left_control, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));
    try c.map(NORMAL, &.{ .left_alt, .left_control, .left_shift, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));
    try c.map(NORMAL, &.{ .left_alt, .left_shift, .left_control, .q }, try AdaptedCb.init(a, sess, WindowManager.closeAllWindows, .{}));

    ///////////////////////////// Spawn Blank Windows

    try mapSpawnBlankWindowKeymaps(sess);

    ///////////////////////////// Undo / Redo

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .z }, try AdaptedCb.init(a, sess, WindowManager.undo, .{})); // to this

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .left_shift, .z }, try AdaptedCb.init(a, sess, WindowManager.redo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_shift, .left_control, .z }, try AdaptedCb.init(a, sess, WindowManager.redo, .{}));

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .left_alt, .z }, try AdaptedCb.init(a, sess, WindowManager.batchUndo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_alt, .left_control, .z }, try AdaptedCb.init(a, sess, WindowManager.batchUndo, .{}));

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .left_shift, .left_alt, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .left_alt, .left_shift, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_shift, .left_control, .left_alt, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_shift, .left_alt, .left_control, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_alt, .left_control, .left_shift, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_alt, .left_shift, .left_control, .z }, try AdaptedCb.init(a, sess, WindowManager.batchRedo, .{}));

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .g, .comma }, try AdaptedCb.init(a, sess, WindowManager.undoWindowSwitch, .{}));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .g, .period }, try AdaptedCb.init(a, sess, WindowManager.redoWindowSwitch, .{}));

    ////////////////////////////////////////////////////////////////////////////////////////////// Multi Win

    try c.map(NORMAL, &.{ .space, .left_control, .j }, try AdaptedCb.init(a, sess, WindowManager.selectActiveWindow, NORMAL_TO_MULTI_WIN));
    try c.map(NORMAL, &.{ .space, .left_control, .l }, try AdaptedCb.init(a, sess, WindowManager.selectAllDescendants, NORMAL_TO_MULTI_WIN));
    try c.map(MULTI_WIN, &.{.escape}, try AdaptedCb.init(a, sess, WindowManager.clearSelection, MULTI_WIN_TO_NORMAL));
}

fn mapSpawnBlankWindowKeymaps(sess: *Session) !void {
    const Cb = struct {
        direction: WindowManager.WindowRelativeDirection,
        sess: *Session,

        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;

            if (wm.active_window == null) {
                const width, const height = wm.mall.icb.getScreenWidthHeight();
                const x, const y = wm.mall.icb.getScreenToWorld2D(wm.mall.camera, width / 2, height / 2);
                try wm.spawnWindow(.string, "", .{ .pos = .{ .x = x, .y = y } }, true, true);
                return;
            }

            try wm.spawnNewWindowRelativeToActiveWindow(.string, "", .{}, self.direction, false);
        }

        pub fn init(allocator: std.mem.Allocator, sess_: *Session, direction: WindowManager.WindowRelativeDirection) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .sess = sess_ };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };

    const c = sess.council;
    const a = c.arena.allocator();
    try c.map(NORMAL, &.{ .left_control, .n }, try Cb.init(a, sess, .bottom));
    try c.map(NORMAL, &.{ .left_control, .left_shift, .n }, try Cb.init(a, sess, .right));
    try c.map(NORMAL, &.{ .left_shift, .left_control, .n }, try Cb.init(a, sess, .right));
}
