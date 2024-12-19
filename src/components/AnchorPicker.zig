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

icb: InfoCallbacks,
rcb: RenderCallbacks,
target_anchor: Anchor = .{},
current_anchor: Anchor = .{},
radius: f32,
color: u32,
lerp_time: f32 = 0.2,
visible: bool = false,

pub fn init(icb: InfoCallbacks, rcb: RenderCallbacks, lerp_time: f32, radius: f32, color: u32) AnchorPicker {
    var self = AnchorPicker{ .icb = icb, .rcb = rcb, .lerp_time = lerp_time, .radius = radius, .color = color };
    const center_anchor = self.getCenter();
    self.current_anchor = center_anchor;
    self.target_anchor = center_anchor;
    return self;
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
    self.rcb.drawCircle(self.current_anchor.x, self.current_anchor.y, self.radius, self.color);
}

pub fn center(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.target_anchor = self.getCenter();
}

pub fn percentage(self: *@This(), x_percent: f32, y_percent: f32) void {
    const width, const height = self.icb.getScreenWidthHeight();
    self.target_anchor = .{ .x = width * x_percent / 100, .y = height * y_percent / 100 };
}

fn getCenter(self: *@This()) Anchor {
    const width, const height = self.icb.getScreenWidthHeight();
    return Anchor{ .x = width / 2, .y = height / 2 };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Anchor = struct {
    x: f32 = 0,
    y: f32 = 0,
};
