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
const rl = @import("raylib");
const SmoothDamper = @import("SmoothDamper.zig");

const Self = @This();

camera: rl.Camera2D = .{
    .offset = .{ .x = 0, .y = 0 },
    .target = .{ .x = 0, .y = 0 },
    .rotation = 0,
    .zoom = 1,
},

target_camera: rl.Camera2D = .{
    .offset = .{ .x = 0, .y = 0 },
    .target = .{ .x = 0, .y = 0 },
    .rotation = 0,
    .zoom = 1,
},

zoom_damper: SmoothDamper = .{},

damp_target: bool = true,
damp_zoom: bool = true,

// TODO: add ways to dynamically change `smooth_time`
x_damper: SmoothDamper = .{ .smooth_time = 0.1, .max_speed = 1000000 },
y_damper: SmoothDamper = .{ .smooth_time = 0.1, .max_speed = 1000000 },

pub fn updateOnNewFrame(self: *@This()) void {
    self.updateOnMouseBtnRight();
    self.updateZoom();

    self.dampTarget();
    // self.lerpTarget();
}

pub fn setTarget(ctx: *anyopaque, x: f32, y: f32) void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.target_camera.target.x = x;
    self.target_camera.target.y = y;
}

fn dampTarget(self: *@This()) void {
    if (!self.damp_target) {
        self.camera.target = self.target_camera.target;
        return;
    }
    self.camera.target.x = self.x_damper.damp(self.camera.target.x, self.target_camera.target.x, rl.getFrameTime());
    self.camera.target.y = self.y_damper.damp(self.camera.target.y, self.target_camera.target.y, rl.getFrameTime());
}
fn lerpTarget(self: *@This()) void {
    self.camera.target.y = rl.math.lerp(self.camera.target.y, self.target_camera.target.y, 0.125);
    self.camera.target.x = rl.math.lerp(self.camera.target.x, self.target_camera.target.x, 0.125);
}

fn updateOnMouseBtnRight(self: *@This()) void {
    if (rl.isMouseButtonDown(.right)) {
        var delta = rl.getMouseDelta();
        delta = delta.scale(-1 / self.camera.zoom);

        self.target_camera.target = delta.add(self.camera.target);
        self.camera.target = self.target_camera.target;
    }
}

fn updateZoom(self: *@This()) void {
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        const mouse_pos = rl.getMousePosition();
        const mouse_world_pos = rl.getScreenToWorld2D(mouse_pos, self.camera);

        self.camera.offset = mouse_pos;
        self.target_camera.offset = mouse_pos;

        self.target_camera.target = mouse_world_pos;
        self.camera.target = mouse_world_pos;

        var scale_factor = 1 + (0.25 * @abs(wheel));
        if (wheel < 0) scale_factor = 1 / scale_factor;

        self.target_camera.zoom = rl.math.clamp(self.target_camera.zoom * scale_factor, 0.125, 64);
    }

    if (!self.damp_zoom) {
        self.camera.zoom = self.target_camera.zoom;
        return;
    }

    // camera.zoom = rl.math.lerp(camera.zoom, cam_zoom_target, 0.25);
    const ft = rl.getFrameTime();
    self.camera.zoom = self.zoom_damper.damp(self.camera.zoom, self.target_camera.zoom, ft);
}
