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
const RenderMall = WindowManager.RenderMall;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,
callback: Callback,
active: bool = false,

hide_active_window_label: bool = false,
hide_selection_window_labels: bool = false,
use_target_camera: bool = true,

pub const Callback = struct {
    f: *const fn (ctx: *anyopaque, window: *Window) anyerror!void,
    ctx: *anyopaque,
};

pub fn render(self: *const @This()) void {
    if (!self.active) return;
    const camera: ?*anyopaque = if (self.use_target_camera) self.wm.mall.target_camera else null;
    const screen_rect = self.wm.mall.getScreenRect(camera);
    self.renderTargetLabels(screen_rect, self.wm.visible_windows.items);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn show(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.active = true;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.active = false;
}

pub fn executeCallback(ctx: *anyopaque, index: usize) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    if (index >= self.wm.visible_windows.items.len or
        index >= RIGHT_HAND_CODEPOINTS.len) return;

    const window = self.wm.visible_windows.items[index];
    try self.callback.f(self.callback.ctx, window);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn renderTargetLabels(self: *const @This(), screen_rect: Rect, windows: []*Window) void {
    for (windows, 0..) |win, i| {
        if (self.hide_active_window_label and (win == self.wm.active_window)) continue;
        if (self.hide_selection_window_labels and self.wm.selection.wmap.get(win) != null) continue;

        const code_point = if (i < RIGHT_HAND_CODEPOINTS.len) RIGHT_HAND_CODEPOINTS[i] else break;

        const r = win.getRect();
        const visible_x = @max(r.x, screen_rect.x);
        const visible_y = @max(r.y, screen_rect.y);
        const visible_width = @min(r.x + r.width, screen_rect.x + screen_rect.width) - visible_x;
        const visible_height = @min(r.y + r.height, screen_rect.y + screen_rect.height) - visible_y;

        // assert(visible_width >= 0 and visible_height >= 0);

        if (visible_width > 0 and visible_height > 0) {
            const visible_center_x = visible_x + visible_width / 2;
            const visible_center_y = visible_y + visible_height / 2;
            renderLabel(self.wm, screen_rect, code_point, visible_center_x, visible_center_y);
        }
    }
}

fn renderLabel(wm: *const WindowManager, screen_rect: Rect, code_point: u21, x: f32, y: f32) void {
    _ = screen_rect;

    const DEFAULT_FONT = wm.mall.font_store.getDefaultFont() orelse unreachable;
    const DEFAULT_GLYPH = DEFAULT_FONT.glyph_map.get('?') orelse unreachable;

    const FONT_SIZE = 60;
    const TEXT_COLOR = 0x0f81d9ff;

    ///////////////////////////// draw circle background

    const CIRCLE_COLOR = 0xffffffff;
    const CIRCLE_PADDING = 0;
    const CIRCLE_RADIUS = FONT_SIZE / 2 + CIRCLE_PADDING;
    wm.mall.rcb.drawCircle(x, y, CIRCLE_RADIUS, CIRCLE_COLOR);

    ///////////////////////////// draw label text

    const char_width = RenderMall.calculateGlyphWidth(DEFAULT_FONT, FONT_SIZE, code_point, DEFAULT_GLYPH);
    const char_height = FONT_SIZE;
    const char_x = x - char_width / 2;
    const char_y = y - char_height / 2;
    wm.mall.rcb.drawCodePoint(DEFAULT_FONT, code_point, char_x, char_y, FONT_SIZE, TEXT_COLOR);
}

////////////////////////////////////////////////////////////////////////////////////////////// WIP

const LEFT_HAND_CODEPOINTS = [_]u21{ 'q', 'w', 'e', 'r', 't', 'a', 's', 'd', 'f', 'g', 'z', 'x', 'c', 'v', 'b' };
const RIGHT_HAND_CODEPOINTS = [_]u21{
    'y', 'u', 'i', 'o', 'p',
    'h', 'j', 'k', 'l', ';',
    'n', 'm', ',', '.', '/',
    '7', '8', '9', '0', '-',
};
