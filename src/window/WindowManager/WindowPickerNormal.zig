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
pub const WindowPicker = @import("WindowPicker.zig");
const Window = WindowManager.Window;

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
    window.centerCameraAt(wm.mall);
}
