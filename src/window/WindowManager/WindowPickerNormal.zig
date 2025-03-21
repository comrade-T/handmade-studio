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

const WindowPickerNormal = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowManager = @import("../WindowManager.zig");
const WindowPicker = @import("WindowPicker.zig");
const Window = WindowManager.Window;

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";

pub fn mapKeys(wpn: *WindowPickerNormal, c: *WindowManager.MappingCouncil) !void {
    const a = c.arena.allocator();

    try c.mapUpNDown(NORMAL, &.{ .space, .f }, .{
        .down_f = WindowPicker.show,
        .up_f = WindowPicker.hide,
        .down_ctx = &wpn.picker,
        .up_ctx = &wpn.picker,
    });

    /////////////////////////////

    const Cb = struct {
        wpn: *WindowPickerNormal,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try WindowPicker.executeCallback(self.wpn, self.index);
        }
        pub fn init(allocator: std.mem.Allocator, wpn_: *WindowPickerNormal, index: usize) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .wpn = wpn_, .index = index };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .f, .y }, try Cb.init(a, wpn, 0));
    try c.map(NORMAL, &.{ .space, .f, .u }, try Cb.init(a, wpn, 1));
    try c.map(NORMAL, &.{ .space, .f, .i }, try Cb.init(a, wpn, 2));
    try c.map(NORMAL, &.{ .space, .f, .o }, try Cb.init(a, wpn, 3));
    try c.map(NORMAL, &.{ .space, .f, .p }, try Cb.init(a, wpn, 4));

    try c.map(NORMAL, &.{ .space, .f, .h }, try Cb.init(a, wpn, 5));
    try c.map(NORMAL, &.{ .space, .f, .j }, try Cb.init(a, wpn, 6));
    try c.map(NORMAL, &.{ .space, .f, .k }, try Cb.init(a, wpn, 7));
    try c.map(NORMAL, &.{ .space, .f, .l }, try Cb.init(a, wpn, 8));
    try c.map(NORMAL, &.{ .space, .f, .semicolon }, try Cb.init(a, wpn, 9));

    try c.map(NORMAL, &.{ .space, .f, .n }, try Cb.init(a, wpn, 10));
    try c.map(NORMAL, &.{ .space, .f, .m }, try Cb.init(a, wpn, 11));
    try c.map(NORMAL, &.{ .space, .f, .comma }, try Cb.init(a, wpn, 12));
    try c.map(NORMAL, &.{ .space, .f, .period }, try Cb.init(a, wpn, 13));
    try c.map(NORMAL, &.{ .space, .f, .slash }, try Cb.init(a, wpn, 14));
}

//////////////////////////////////////////////////////////////////////////////////////////////

picker: WindowPicker,

pub fn create(a: Allocator, wm: *WindowManager) !*WindowPickerNormal {
    const self = try a.create(@This());
    self.* = WindowPickerNormal{
        .picker = WindowPicker{
            .wm = wm,
            .callback = .{ .f = callback, .ctx = self },
        },
    };
    return self;
}

pub fn destroy(self: *@This(), a: Allocator) void {
    a.destroy(self);
}

fn callback(ctx: *anyopaque, window: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const wm = self.picker.wm;
    wm.setActiveWindow(window);
    window.centerCameraAt(wm.mall.getScreenRect(), wm.mall);
}
