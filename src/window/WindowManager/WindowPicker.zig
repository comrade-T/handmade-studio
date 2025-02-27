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

const WindowPicker = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowManager = @import("../WindowManager.zig");
const Window = WindowManager.Window;
const Rect = WindowManager.Rect;
const WindowList = WindowManager.WindowList;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *const WindowManager,
active: bool = false,

pub fn toggle(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.active = !self.active;
}

pub fn render(self: *const @This(), screen_rect: Rect) void {
    if (!self.active) return;
    self.renderTargetLabels(screen_rect, self.wm.visible_windows.items);
}

fn renderTargetLabels(self: *const @This(), screen_rect: Rect, windows: []*Window) void {
    for (windows) |win| {
        const r = win.getRect();
        const visible_x = @max(r.x, screen_rect.x);
        const visible_y = @max(r.y, screen_rect.y);
        const visible_width = @min(r.x + r.width, screen_rect.x + screen_rect.width) - visible_x;
        const visible_height = @min(r.y + r.height, screen_rect.y + screen_rect.height) - visible_y;

        assert(visible_width >= 0 and visible_height >= 0);

        if (visible_width > 0 and visible_height > 0) {
            const visible_center_x = visible_x + visible_width / 2;
            const visible_center_y = visible_y + visible_height / 2;
            renderLabel(self.wm, screen_rect, visible_center_x, visible_center_y);
        }
    }
}

fn renderLabel(wm: *const WindowManager, screen_rect: Rect, x: f32, y: f32) void {
    _ = screen_rect;

    const font = wm.mall.font_store.getDefaultFont() orelse unreachable;

    const CODE_POINT = '?';
    const FONT_SIZE = 60;
    const COLOR = 0x22d3d6ff;

    wm.mall.rcb.drawCodePoint(font, CODE_POINT, x, y, FONT_SIZE, COLOR);

    // TODO: render a circle background

    // ACTUAL TODOS:
    // 1. calculate the size of the text
    // 2. calculate the background circle size base on that text
    // 3. render the circle
    // 4. render the text w/ rcb.drawCodePoint()

}

////////////////////////////////////////////////////////////////////////////////////////////// TODOS after finishing renderLabel()

// TODO: center view at window
// TODO: make view so that window at the right of the screen (with padding)
// TODO: make view so that window at the left of the screen (with padding)
// TODO: make view so that window at the top of the screen (with padding)
// TODO: make view so that window at the bottom of the screen (with padding)
