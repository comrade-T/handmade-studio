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

const AnchorPicker = @This();
const std = @import("std");

const RenderMall = @import("RenderMall");
const RenderCallbacks = RenderMall.RenderCallbacks;
const InfoCallbacks = RenderMall.InfoCallbacks;

//////////////////////////////////////////////////////////////////////////////////////////////

mall: *RenderMall,

target_anchor: Anchor = .{},
current_anchor: Anchor = .{},

radius: f32,
color: u32,
lerp_time: f32,

visible: bool = false,

pub fn setToCenter(self: *@This()) void {
    const center_anchor = self.getCenter();
    self.current_anchor = center_anchor;
    self.target_anchor = center_anchor;
}

pub fn show(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.visible = true;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.visible = false;
}

pub fn render(self: *@This()) void {
    if (!self.visible) return;
    self.current_anchor.x = RenderMall.lerp(self.current_anchor.x, self.target_anchor.x, self.lerp_time);
    self.current_anchor.y = RenderMall.lerp(self.current_anchor.y, self.target_anchor.y, self.lerp_time);
    self.mall.rcb.drawCircle(self.current_anchor.x, self.current_anchor.y, self.radius, self.color);
}

pub fn center(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.target_anchor = self.getCenter();
}

pub fn percentage(self: *@This(), x_percent: f32, y_percent: f32) void {
    const width, const height = self.mall.icb.getScreenWidthHeight();
    self.target_anchor = .{ .x = width * x_percent / 100, .y = height * y_percent / 100 };
}

pub fn zoom(self: *@This(), scale_factor: f32) void {
    self.mall.rcb.changeCameraZoom(self.mall.camera, self.mall.target_camera, self.target_anchor.x, self.target_anchor.y, scale_factor);
    self.mall.camera_just_moved = true;
}

pub fn pan(self: *@This(), x_by: f32, y_by: f32) void {
    self.mall.rcb.changeCameraPan(self.mall.target_camera, x_by, y_by);
    self.mall.camera_just_moved = true;
}

fn getCenter(self: *@This()) Anchor {
    const width, const height = self.mall.icb.getScreenWidthHeight();
    return Anchor{ .x = width / 2, .y = height / 2 };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Anchor = struct {
    x: f32 = 0,
    y: f32 = 0,
};
