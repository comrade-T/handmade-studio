const rl = @import("raylib");

camera: rl.Camera2D = .{
    .offset = .{ .x = 0, .y = 0 },
    .target = .{ .x = 0, .y = 0 },
    .rotation = 0,
    .zoom = 1,
},

zoom_target: f32 = 1,
current_velocity: f32 = 0,
smooth_time: f32 = 0.1,
max_speed: f32 = 40,

pub fn update(self: *@This()) void {
    self.updateTarget();
    self.updateZoom();
}

fn updateTarget(self: *@This()) void {
    if (rl.isMouseButtonDown(.mouse_button_right)) {
        var delta = rl.getMouseDelta();
        delta = delta.scale(-1 / self.camera.zoom);
        self.camera.target = delta.add(self.camera.target);
    }
}

fn updateZoom(self: *@This()) void {
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        const mouse_pos = rl.getMousePosition();
        const mouse_world_pos = rl.getScreenToWorld2D(mouse_pos, self.camera);
        self.camera.offset = mouse_pos;
        self.camera.target = mouse_world_pos;

        var scale_factor = 1 + (0.25 * @abs(wheel));
        if (wheel < 0) scale_factor = 1 / scale_factor;

        self.zoom_target = rl.math.clamp(self.zoom_target * scale_factor, 0.125, 64);
    }

    // camera.zoom = rl.math.lerp(camera.zoom, cam_zoom_target, 0.25);
    self.camera.zoom = smoothDamp(self.camera.zoom, self.zoom_target, &self.current_velocity, self.smooth_time, self.max_speed, rl.getFrameTime());
}

// https://stackoverflow.com/questions/61372498/how-does-mathf-smoothdamp-work-what-is-it-algorithm
fn smoothDamp(current: f32, target_: f32, current_velocity: *f32, smooth_time_: f32, max_speed: f32, delta_time: f32) f32 {
    const smooth_time = @max(0.0001, smooth_time_);
    var target = target_;

    const omega = 2 / smooth_time;

    const x = omega * delta_time;
    const exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
    var change = current - target;
    const original_to = target;

    const max_change = max_speed * smooth_time;
    change = rl.math.clamp(change, -max_change, max_change);
    target = current - change;

    const temp = (current_velocity.* + omega * change) * delta_time;
    current_velocity.* = (current_velocity.* - omega * temp) * exp;
    var output = target + (change + temp) * exp;

    if (original_to - current > 0 and output > original_to) {
        output = original_to;
        current_velocity.* = (output - original_to) / delta_time;
    }

    return output;
}
