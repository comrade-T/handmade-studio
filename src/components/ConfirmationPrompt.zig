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

const ConfirmationPrompt = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const code_point = @import("code_point");
const RenderMall = @import("RenderMall");
const ip = @import("input_processor");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
mall: *const RenderMall,
council: *ip.MappingCouncil,

callbacks: Callbacks = .{},
y_offset: f32 = 50,
font_size: f32 = 30,
text_color: u32 = 0xf78c6cff,
visible: bool = false,
message: ?[]const u8 = null,

const NORMAL = "normal";
const CP = "ConfirmationPrompt";

const Callbacks = struct {
    onConfirm: ?Callback = null,
    onCancel: ?Callback = null,

    const Callback = struct {
        f: *const fn (ctx: *anyopaque) anyerror!void,
        ctx: *anyopaque,
    };
};

pub fn mapKeys(cp: *@This()) !void {
    const c = cp.council;
    try c.map(CP, &.{.y}, .{ .f = yes, .ctx = cp });
    try c.map(CP, &.{.escape}, .{ .f = no, .ctx = cp });
    try c.map(CP, &.{.n}, .{ .f = no, .ctx = cp });
}

pub fn deinit(self: *@This()) void {
    self.freeMessage();
}

pub fn show(self: *@This(), msg: []const u8, callbacks: Callbacks) !void {
    self.freeMessage();
    self.callbacks = callbacks;
    self.message = try self.a.dupe(u8, msg);

    try self.council.addActiveContext(CP);
    self.council.restrictTriggersToLatestContextOnly();
    self.assertCorrectMappingContext();
}

pub fn render(self: *@This()) void {
    const message = self.message orelse return;

    const font = self.mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = font.glyph_map.get('?') orelse unreachable;

    const screen_rect = self.mall.getScreenRect();

    var x: f32 = screen_rect.x;
    const y: f32 = screen_rect.height - self.font_size - self.y_offset;

    var cp_iter = code_point.Iterator{ .bytes = message };
    while (cp_iter.next()) |cp| {
        const char_width = RenderMall.calculateGlyphWidth(font, self.font_size, cp.code, default_glyph);
        defer x += char_width;

        self.mall.rcb.drawCodePoint(font, cp.code, x, y, self.font_size, self.text_color);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn yes(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.callbacks.onConfirm) |onConfirm| try onConfirm.f(onConfirm.ctx);
    self.hide();
}

fn no(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.callbacks.onCancel) |onCancel| try onCancel.f(onCancel.ctx);
    self.hide();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn hide(self: *@This()) void {
    self.freeMessage();
    try self.council.removeActiveContext(CP);
    self.council.removeTriggerRestrictions();
}

fn assertCorrectMappingContext(self: *@This()) void {
    const active_contexts = self.council.active_contexts.keys();
    assert(active_contexts.len > 0);
    assert(std.mem.eql(u8, active_contexts[active_contexts.len - 1], CP));
}

fn freeMessage(self: *@This()) void {
    if (self.message == null) return;
    self.a.free(self.message.?);
    self.message = null;
}
