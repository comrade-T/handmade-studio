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

pub fn update(self: *@This()) void {
    self.updateTarget();
    self.updateZoom();
}

fn updateTarget(self: *@This()) void {
    if (rl.isMouseButtonDown(.mouse_button_right)) {
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

        self.target_camera.target = mouse_world_pos;
        self.camera.target = mouse_world_pos;

        var scale_factor = 1 + (0.25 * @abs(wheel));
        if (wheel < 0) scale_factor = 1 / scale_factor;

        self.target_camera.zoom = rl.math.clamp(self.target_camera.zoom * scale_factor, 0.125, 64);
    }

    // camera.zoom = rl.math.lerp(camera.zoom, cam_zoom_target, 0.25);
    self.camera.zoom = self.zoom_damper.damp(self.camera.zoom, self.target_camera.zoom, rl.getFrameTime());
}
