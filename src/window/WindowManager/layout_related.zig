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
const WindowManager = @import("../WindowManager.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";

pub fn mapKeys(wm: *WindowManager, c: *WindowManager.MappingCouncil) !void {
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
        wm: *WindowManager,
        x: f32,
        y: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try moveActiveWindowBy(self.wm, self.x, self.y);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, x: f32, y: f32) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .wm = wm_, .x = x, .y = y };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .m, .a }, try MoveByCb.init(a, wm, -100, 0));
    try c.map(NORMAL, &.{ .m, .d }, try MoveByCb.init(a, wm, 100, 0));
    try c.map(NORMAL, &.{ .m, .w }, try MoveByCb.init(a, wm, 0, -100));
    try c.map(NORMAL, &.{ .m, .s }, try MoveByCb.init(a, wm, 0, 100));

    // change window padding
    const ChangePaddingByCb = struct {
        wm: *WindowManager,
        x_by: f32,
        y_by: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try changeActiveWindowPaddingBy(self.wm, self.x_by, self.y_by);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, x_by: f32, y_by: f32) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .wm = wm_, .x_by = x_by, .y_by = y_by };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .p, .a }, try ChangePaddingByCb.init(a, wm, -10, 0));
    try c.map(NORMAL, &.{ .space, .p, .d }, try ChangePaddingByCb.init(a, wm, 10, 0));
    try c.map(NORMAL, &.{ .space, .p, .w }, try ChangePaddingByCb.init(a, wm, 0, 10));
    try c.map(NORMAL, &.{ .space, .p, .s }, try ChangePaddingByCb.init(a, wm, 0, -10));

    // change window bound size
    const ChangeBoundSizeByCb = struct {
        wm: *WindowManager,
        width_by: f32,
        height_by: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            changeActiveWindowBoundSizeBy(self.wm, self.width_by, self.height_by);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, width_by: f32, height_by: f32) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .wm = wm_, .width_by = width_by, .height_by = height_by };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .b, .k }, try ChangeBoundSizeByCb.init(a, wm, 0, -20));
    try c.map(NORMAL, &.{ .space, .b, .j }, try ChangeBoundSizeByCb.init(a, wm, 0, 20));
    try c.map(NORMAL, &.{ .space, .b, .h }, try ChangeBoundSizeByCb.init(a, wm, -20, 0));
    try c.map(NORMAL, &.{ .space, .b, .l }, try ChangeBoundSizeByCb.init(a, wm, 20, 0));
    try c.map(NORMAL, &.{ .space, .b }, .{ .f = toggleActiveWindowBounds, .ctx = wm, .require_clarity_afterwards = true });

    // switch active window
    const SwitchActiveWinCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        wm: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try makeClosestWindowActive(self.wm, self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, direction: WindowManager.WindowRelativeDirection) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .wm = wm_ };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .left_control, .h }, try SwitchActiveWinCb.init(a, wm, .left));
    try c.map(NORMAL, &.{ .left_control, .l }, try SwitchActiveWinCb.init(a, wm, .right));
    try c.map(NORMAL, &.{ .left_control, .k }, try SwitchActiveWinCb.init(a, wm, .top));
    try c.map(NORMAL, &.{ .left_control, .j }, try SwitchActiveWinCb.init(a, wm, .bottom));

    // toggle border
    try c.map(NORMAL, &.{ .left_control, .b }, .{ .f = toggleActiveWindowBorder, .ctx = wm });
}

////////////////////////////////////////////////////////////////////////////////////////////// Positioning

pub fn centerActiveWindowAt(wm: *WindowManager, center_x: f32, center_y: f32) void {
    const active_window = wm.active_window orelse return;
    active_window.centerAt(center_x, center_y);
}

pub fn moveActiveWindowBy(wm: *WindowManager, x_by: f32, y_by: f32) !void {
    const active_window = wm.active_window orelse return;
    try active_window.moveBy(wm.a, wm.qtree, &wm.updating_windows_map, x_by, y_by);
    wm.cleanUpWindowsAfterAppendingToHistory(
        wm.a,
        try wm.hm.addMoveEvent(wm.a, active_window, x_by, y_by),
    );
}

pub fn toggleActiveWindowBorder(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
    const active_window = wm.active_window orelse return;
    active_window.toggleBorder();
    wm.cleanUpWindowsAfterAppendingToHistory(
        wm.a,
        try wm.hm.addToggleBorderEvent(wm.a, active_window),
    );
}

pub fn changeActiveWindowPaddingBy(wm: *WindowManager, x_by: f32, y_by: f32) !void {
    const active_window = wm.active_window orelse return;
    try active_window.changePaddingBy(wm.a, wm.qtree, x_by, y_by);
    wm.cleanUpWindowsAfterAppendingToHistory(
        wm.a,
        try wm.hm.addChangePaddingEvent(wm.a, active_window, x_by, y_by),
    );
}

pub fn toggleActiveWindowBounds(ctx: *anyopaque) !void {
    const wm = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
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
    if (may_candidate) |candidate| wm.active_window = candidate;
}
