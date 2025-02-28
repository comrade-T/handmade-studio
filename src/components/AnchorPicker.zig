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

const ip = @import("input_processor");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const AP = "anchor_picker";

const NORMAL_TO_AP = ip.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{AP} };
const AP_TO_NORMAL = ip.Callback.Contexts{ .remove = &.{AP}, .add = &.{NORMAL} };

pub fn mapKeys(ap: *@This(), c: *ip.MappingCouncil) !void {
    const a = c.arena.allocator();
    try c.map(NORMAL, &.{ .left_control, .p }, .{ .f = show, .ctx = ap, .contexts = NORMAL_TO_AP, .require_clarity_afterwards = true });
    try c.map(AP, &.{.escape}, .{ .f = hide, .ctx = ap, .contexts = AP_TO_NORMAL });

    ///////////////////////////// anchor position

    const PercentageCb = struct {
        x_percent: f32,
        y_percent: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.percentage(self.x_percent, self.y_percent);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, x_percent: f32, y_percent: f32) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .x_percent = x_percent, .y_percent = y_percent };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };

    try c.map(AP, &.{ .p, .c }, .{ .f = AnchorPicker.center, .ctx = ap });
    try c.map(AP, &.{ .p, .w }, try PercentageCb.init(a, ap, 50, 25));
    try c.map(AP, &.{ .p, .s }, try PercentageCb.init(a, ap, 50, 75));
    try c.map(AP, &.{ .p, .a }, try PercentageCb.init(a, ap, 25, 50));
    try c.map(AP, &.{ .p, .d }, try PercentageCb.init(a, ap, 75, 50));

    try c.mapUpNDown(NORMAL, &.{ .z, .c }, .{ .down_f = show, .up_f = hide, .down_ctx = ap, .up_ctx = ap });
    try c.map(NORMAL, &.{ .z, .c, .m }, .{ .f = AnchorPicker.center, .ctx = ap });
    try c.map(NORMAL, &.{ .z, .c, .k }, try PercentageCb.init(a, ap, 50, 25));
    try c.map(NORMAL, &.{ .z, .c, .j }, try PercentageCb.init(a, ap, 50, 75));
    try c.map(NORMAL, &.{ .z, .c, .h }, try PercentageCb.init(a, ap, 25, 50));
    try c.map(NORMAL, &.{ .z, .c, .l }, try PercentageCb.init(a, ap, 75, 50));

    ///////////////////////////// zoom

    const ZoomCb = struct {
        scale_factor: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.zoom(self.scale_factor);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, scale_factor: f32, ignore_trigger_delay: bool) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .scale_factor = scale_factor };
            return ip.Callback{ .f = @This().f, .ctx = self, .ignore_trigger_delay = ignore_trigger_delay };
        }
    };

    try c.map(AP, &.{ .z, .j }, try ZoomCb.init(a, ap, 0.9, true));
    try c.map(AP, &.{ .z, .k }, try ZoomCb.init(a, ap, 1.1, true));
    try c.map(AP, &.{ .z, .space, .j }, try ZoomCb.init(a, ap, 0.8, false));
    try c.map(AP, &.{ .z, .space, .k }, try ZoomCb.init(a, ap, 1.25, false));

    try c.mapUpNDown(NORMAL, &.{ .z, .x }, .{ .down_f = show, .up_f = hide, .down_ctx = ap, .up_ctx = ap });
    try c.map(NORMAL, &.{ .z, .x, .j }, try ZoomCb.init(a, ap, 0.8, false));
    try c.map(NORMAL, &.{ .z, .x, .k }, try ZoomCb.init(a, ap, 1.25, false));
    try c.map(NORMAL, &.{ .z, .x, .space, .j }, try ZoomCb.init(a, ap, 0.9, true));
    try c.map(NORMAL, &.{ .z, .x, .space, .k }, try ZoomCb.init(a, ap, 1.1, true));

    ///////////////////////////// pan

    const PanCb = struct {
        x_by: f32,
        y_by: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.pan(self.x_by, self.y_by);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, x_by: f32, y_by: f32, ignore_trigger_delay: bool) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .x_by = x_by, .y_by = y_by };
            return ip.Callback{
                .f = @This().f,
                .ctx = self,
                .always_trigger_on_down = true,
                .ignore_trigger_delay = ignore_trigger_delay,
            };
        }
    };

    try c.map(NORMAL, &.{ .z, .k }, try PanCb.init(a, ap, 0, -100, false));
    try c.map(NORMAL, &.{ .z, .j }, try PanCb.init(a, ap, 0, 100, false));
    try c.map(NORMAL, &.{ .z, .h }, try PanCb.init(a, ap, -100, 0, false));
    try c.map(NORMAL, &.{ .z, .l }, try PanCb.init(a, ap, 100, 0, false));
    try c.map(NORMAL, &.{ .z, .k, .h }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(NORMAL, &.{ .z, .k, .l }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(NORMAL, &.{ .z, .j, .h }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(NORMAL, &.{ .z, .j, .l }, try PanCb.init(a, ap, 100, 100, false));
    try c.map(NORMAL, &.{ .z, .h, .k }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(NORMAL, &.{ .z, .h, .j }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(NORMAL, &.{ .z, .l, .k }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(NORMAL, &.{ .z, .l, .j }, try PanCb.init(a, ap, 100, 100, false));

    try c.map(NORMAL, &.{ .z, .space, .k }, try PanCb.init(a, ap, 0, -100, true));
    try c.map(NORMAL, &.{ .z, .space, .j }, try PanCb.init(a, ap, 0, 100, true));
    try c.map(NORMAL, &.{ .z, .space, .h }, try PanCb.init(a, ap, -100, 0, true));
    try c.map(NORMAL, &.{ .z, .space, .l }, try PanCb.init(a, ap, 100, 0, true));
    try c.map(NORMAL, &.{ .z, .k, .space, .h }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(NORMAL, &.{ .z, .k, .space, .l }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(NORMAL, &.{ .z, .j, .space, .h }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(NORMAL, &.{ .z, .j, .space, .l }, try PanCb.init(a, ap, 100, 100, true));
    try c.map(NORMAL, &.{ .z, .h, .space, .k }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(NORMAL, &.{ .z, .h, .space, .j }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(NORMAL, &.{ .z, .l, .space, .k }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(NORMAL, &.{ .z, .l, .space, .j }, try PanCb.init(a, ap, 100, 100, true));

    try c.map(AP, &.{.w}, try PanCb.init(a, ap, 0, -100, true));
    try c.map(AP, &.{.s}, try PanCb.init(a, ap, 0, 100, true));
    try c.map(AP, &.{.a}, try PanCb.init(a, ap, -100, 0, true));
    try c.map(AP, &.{.d}, try PanCb.init(a, ap, 100, 0, true));
    try c.map(AP, &.{ .w, .a }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(AP, &.{ .s, .a }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(AP, &.{ .a, .w }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(AP, &.{ .a, .s }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(AP, &.{ .w, .d }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(AP, &.{ .s, .d }, try PanCb.init(a, ap, 100, 100, true));
    try c.map(AP, &.{ .d, .w }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(AP, &.{ .d, .s }, try PanCb.init(a, ap, 100, 100, true));
    try c.map(AP, &.{ .space, .w }, try PanCb.init(a, ap, 0, -100, false));
    try c.map(AP, &.{ .space, .s }, try PanCb.init(a, ap, 0, 100, false));
    try c.map(AP, &.{ .space, .a }, try PanCb.init(a, ap, -100, 0, false));
    try c.map(AP, &.{ .space, .d }, try PanCb.init(a, ap, 100, 0, false));
    try c.map(AP, &.{ .space, .w, .a }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(AP, &.{ .space, .s, .a }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(AP, &.{ .space, .a, .w }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(AP, &.{ .space, .a, .s }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(AP, &.{ .space, .w, .d }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(AP, &.{ .space, .s, .d }, try PanCb.init(a, ap, 100, 100, false));
    try c.map(AP, &.{ .space, .d, .w }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(AP, &.{ .space, .d, .s }, try PanCb.init(a, ap, 100, 100, false));

    try c.map(AP, &.{ .m, .w }, try PanCb.init(a, ap, 0, -100, true));
    try c.map(AP, &.{ .m, .s }, try PanCb.init(a, ap, 0, 100, true));
    try c.map(AP, &.{ .m, .a }, try PanCb.init(a, ap, -100, 0, true));
    try c.map(AP, &.{ .m, .d }, try PanCb.init(a, ap, 100, 0, true));
    try c.map(AP, &.{ .m, .w, .a }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(AP, &.{ .m, .s, .a }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(AP, &.{ .m, .a, .w }, try PanCb.init(a, ap, -100, -100, true));
    try c.map(AP, &.{ .m, .a, .s }, try PanCb.init(a, ap, -100, 100, true));
    try c.map(AP, &.{ .m, .w, .d }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(AP, &.{ .m, .s, .d }, try PanCb.init(a, ap, 100, 100, true));
    try c.map(AP, &.{ .m, .d, .w }, try PanCb.init(a, ap, 100, -100, true));
    try c.map(AP, &.{ .m, .d, .s }, try PanCb.init(a, ap, 100, 100, true));
    try c.map(AP, &.{ .m, .space, .w }, try PanCb.init(a, ap, 0, -100, false));
    try c.map(AP, &.{ .m, .space, .s }, try PanCb.init(a, ap, 0, 100, false));
    try c.map(AP, &.{ .m, .space, .a }, try PanCb.init(a, ap, -100, 0, false));
    try c.map(AP, &.{ .m, .space, .d }, try PanCb.init(a, ap, 100, 0, false));
    try c.map(AP, &.{ .m, .space, .w, .a }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(AP, &.{ .m, .space, .s, .a }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(AP, &.{ .m, .space, .a, .w }, try PanCb.init(a, ap, -100, -100, false));
    try c.map(AP, &.{ .m, .space, .a, .s }, try PanCb.init(a, ap, -100, 100, false));
    try c.map(AP, &.{ .m, .space, .w, .d }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(AP, &.{ .m, .space, .s, .d }, try PanCb.init(a, ap, 100, 100, false));
    try c.map(AP, &.{ .m, .space, .d, .w }, try PanCb.init(a, ap, 100, -100, false));
    try c.map(AP, &.{ .m, .space, .d, .s }, try PanCb.init(a, ap, 100, 100, false));
}

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
