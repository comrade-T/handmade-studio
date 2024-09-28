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

x_damper: SmoothDamper = .{ .smooth_time = 0.1, .max_speed = 8000 },
y_damper: SmoothDamper = .{ .smooth_time = 0.1, .max_speed = 8000 },

pub fn updateOnNewFrame(self: *@This()) void {
    self.updateOnMouseBtnRight();
    self.updateZoom();
    self.dampTarget();
}

pub fn setTarget(ctx: *anyopaque, x: f32, y: f32) void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.target_camera.target.x = x;
    self.target_camera.target.y = y;
}

fn dampTarget(self: *@This()) void {
    self.camera.target.y = self.y_damper.damp(
        self.camera.target.y,
        self.target_camera.target.y,
        rl.getFrameTime(),
    );
    self.camera.target.x = self.x_damper.damp(
        self.camera.target.x,
        self.target_camera.target.x,
        rl.getFrameTime(),
    );
}

fn updateOnMouseBtnRight(self: *@This()) void {
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
