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

const NORMAL = "normal";

pub fn mapKeys(wm: *WindowManager, c: *WindowManager.MappingCouncil) !void {
    const a = c.arena.allocator();
    const wp = &wm.window_picker;

    try c.mapUpNDown(NORMAL, &.{.space}, .{ .down_f = show, .up_f = hide, .down_ctx = wp, .up_ctx = wp });

    /////////////////////////////

    const MoveToCb = struct {
        wm: *WindowManager,
        index: usize,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.wm.window_picker.moveTo(self.index);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, index: usize) !WindowManager.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .wm = wm_, .index = index };
            return WindowManager.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try c.map(NORMAL, &.{ .space, .y }, try MoveToCb.init(a, wm, 0));
    try c.map(NORMAL, &.{ .space, .u }, try MoveToCb.init(a, wm, 1));
    try c.map(NORMAL, &.{ .space, .i }, try MoveToCb.init(a, wm, 2));
    try c.map(NORMAL, &.{ .space, .o }, try MoveToCb.init(a, wm, 3));
    try c.map(NORMAL, &.{ .space, .p }, try MoveToCb.init(a, wm, 4));

    try c.map(NORMAL, &.{ .space, .h }, try MoveToCb.init(a, wm, 5));
    try c.map(NORMAL, &.{ .space, .j }, try MoveToCb.init(a, wm, 6));
    try c.map(NORMAL, &.{ .space, .k }, try MoveToCb.init(a, wm, 7));
    try c.map(NORMAL, &.{ .space, .l }, try MoveToCb.init(a, wm, 8));
    try c.map(NORMAL, &.{ .space, .semicolon }, try MoveToCb.init(a, wm, 9));

    try c.map(NORMAL, &.{ .space, .n }, try MoveToCb.init(a, wm, 10));
    try c.map(NORMAL, &.{ .space, .m }, try MoveToCb.init(a, wm, 11));
    try c.map(NORMAL, &.{ .space, .comma }, try MoveToCb.init(a, wm, 12));
    try c.map(NORMAL, &.{ .space, .period }, try MoveToCb.init(a, wm, 13));
    try c.map(NORMAL, &.{ .space, .slash }, try MoveToCb.init(a, wm, 14));
}

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,
active: bool = false,

pub fn render(self: *const @This(), screen_rect: Rect) void {
    if (!self.active) return;
    self.renderTargetLabels(screen_rect, self.wm.visible_windows.items);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn show(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.active = true;
}

fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.active = false;
}

fn moveTo(self: *@This(), index: usize) void {
    if (index >= self.wm.visible_windows.items.len or
        index >= RIGHT_HAND_CODEPOINTS.len) return;

    const window = self.wm.visible_windows.items[index];
    self.wm.setActiveWindow(window);

    /////////////////////////////

    window.centerCameraAt(self.wm.mall);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn renderTargetLabels(self: *const @This(), screen_rect: Rect, windows: []*Window) void {
    for (windows, 0..) |win, i| {
        if (win == self.wm.active_window) continue;
        const code_point = if (i < RIGHT_HAND_CODEPOINTS.len) RIGHT_HAND_CODEPOINTS[i] else break;

        const r = win.getRect();
        const visible_x = @max(r.x, screen_rect.x);
        const visible_y = @max(r.y, screen_rect.y);
        const visible_width = @min(r.x + r.width, screen_rect.x + screen_rect.width) - visible_x;
        const visible_height = @min(r.y + r.height, screen_rect.y + screen_rect.height) - visible_y;

        assert(visible_width >= 0 and visible_height >= 0);

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
};

////////////////////////////////////////////////////////////////////////////////////////////// TODOS after finishing renderLabel()

// TODO: center view at window
// TODO: make view so that window at the right of the screen (with padding)
// TODO: make view so that window at the left of the screen (with padding)
// TODO: make view so that window at the top of the screen (with padding)
// TODO: make view so that window at the bottom of the screen (with padding)
