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
const Anchor = WindowManager.ConnectionManager.Connection.Anchor;
const Callback = Session.Callback;

const NORMAL = "normal";
pub const MULTI_WIN = "MULTI_WIN";

pub const MULTI_WIN_TO_NORMAL = Callback.Contexts{ .remove = &.{MULTI_WIN}, .add = &.{NORMAL} };
pub const NORMAL_TO_MULTI_WIN = Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{MULTI_WIN} };

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

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .left_control, .q }, try AdaptedCb.init(a, sess, WindowManager.closeActiveWindows, .{}));

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

    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .left_control, .j }, try AdaptedCb.init(a, sess, WindowManager.toggleActiveWindowFromSelection, NORMAL_TO_MULTI_WIN));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .left_control, .l }, try AdaptedCb.init(a, sess, WindowManager.selectAllDescendants, NORMAL_TO_MULTI_WIN));
    try c.mmc(&.{ NORMAL, MULTI_WIN }, &.{ .space, .left_control, .a }, try AdaptedCb.init(a, sess, WindowManager.selectAllConnectedWindowsRecursively, NORMAL_TO_MULTI_WIN));
    try c.map(MULTI_WIN, &.{.escape}, try AdaptedCb.init(a, sess, WindowManager.clearSelection, MULTI_WIN_TO_NORMAL));
}

fn mapSpawnBlankWindowKeymaps(sess: *Session) !void {
    const EstablishConnectionType = enum { none, horizontal, vertical };
    const Cb = struct {
        sess: *Session,
        spawn_opts: WindowManager.SpawnRelativeeWindowOpts,
        establish_connection: EstablishConnectionType,

        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const wm = self.sess.getActiveCanvasWindowManager() orelse return;

            if (wm.active_window == null) {
                const width, const height = wm.mall.icb.getScreenWidthHeight();
                const x, const y = wm.mall.icb.getScreenToWorld2D(wm.mall.camera, width / 2, height / 2);
                const b = try wm.spawnWindow(.string, "", .{ .pos = .{ .x = x, .y = y } }, true, true);
                try wm.triggerCursorEnterAnimation(b);
                return;
            }

            const a = wm.active_window orelse return;
            const b = try wm.spawnNewWindowRelativeToActiveWindow(.string, "", .{ .pos = .{} }, self.spawn_opts) orelse return;

            try wm.triggerCursorExitAnimation(a);
            try wm.triggerCursorEnterAnimation(b);

            const a_anchor, const b_anchor = switch (self.establish_connection) {
                .none => return,
                .horizontal => .{ Anchor.E, Anchor.W },
                .vertical => .{ Anchor.S, Anchor.N },
            };
            try wm.connman.establishHardCodedPendingConnection(a, a_anchor, b, b_anchor);
        }

        pub fn init(
            allocator: std.mem.Allocator,
            sess_: *Session,
            spawn_opts: WindowManager.SpawnRelativeeWindowOpts,
            establish_connection: EstablishConnectionType,
        ) !Session.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .sess = sess_, .spawn_opts = spawn_opts, .establish_connection = establish_connection };
            return Session.Callback{ .f = @This().f, .ctx = self };
        }
    };

    const c = sess.council;
    const a = c.arena.allocator();
    try c.map(NORMAL, &.{ .left_control, .n }, try Cb.init(a, sess, .{ .direction = .bottom, .x_by = 0, .y_by = 100 }, .none));
    try c.map(NORMAL, &.{ .left_control, .left_shift, .n }, try Cb.init(a, sess, .{ .direction = .right, .x_by = 200, .y_by = 0 }, .none));
    try c.map(NORMAL, &.{ .left_shift, .left_control, .n }, try Cb.init(a, sess, .{ .direction = .right, .x_by = 200, .y_by = 0 }, .none));

    try c.map(NORMAL, &.{ .left_control, .c, .n }, try Cb.init(a, sess, .{ .direction = .bottom, .x_by = 0, .y_by = 100 }, .vertical));
    try c.map(NORMAL, &.{ .left_control, .left_shift, .c, .n }, try Cb.init(a, sess, .{ .direction = .right, .x_by = 200, .y_by = 0 }, .horizontal));
    try c.map(NORMAL, &.{ .left_shift, .left_control, .c, .n }, try Cb.init(a, sess, .{ .direction = .right, .x_by = 200, .y_by = 0 }, .horizontal));
}
