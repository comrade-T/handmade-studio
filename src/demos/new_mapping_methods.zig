const std = @import("std");
const rl = @import("raylib");

const _input_processor = @import("input_processor");
const InputFrame = _input_processor.InputFrame;
const Key = _input_processor.Key;
const MappingCouncil = _input_processor.MappingCouncil;

const TheList = @import("TheList");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// OpenGL Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "NewMappingMethods");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Camera2D

    var smooth_camera = Smooth2DCamera{};

    ///////////////////////////// General Purpose Allocator

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    ///////////////////////////// MappingCouncil

    var council = try MappingCouncil.init(gpa);
    defer council.deinit();

    ///////////////////////////// InputFrame

    var frame = try InputFrame.init(gpa);
    defer frame.deinit();

    ///////////////////////////// InputRepeatManager

    // var last_trigger_timestamp: i64 = 0;
    // var last_trigger: u128 = 0;

    var irm = InputRepeatManager{};

    // const trigger_delay = 150;
    // const repeat_rate = 1000 / 62;

    ///////////////////////////// FileNavigator

    var list_items = [_][:0]const u8{ "hello", "from", "the", "other", "side" };
    const the_list = TheList{
        .visible = true,
        .items = &list_items,
        .x = 400,
        .y = 200,
        .line_height = 45,
    };

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        { // Inputs
            try updateInputState(&frame, &irm);
        }

        { // Camera
            smooth_camera.update();
        }

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            rl.drawFPS(10, 10);

            {
                rl.beginMode2D(smooth_camera.camera);
                defer rl.endMode2D();

                rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);

                // TheList
                {
                    var iter = the_list.iter();
                    while (iter.next()) |r| {
                        const color = if (r.active) rl.Color.sky_blue else rl.Color.ray_white;
                        rl.drawText(r.text, r.x, r.y, r.font_size, color);
                    }
                }
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const InputRepeatManager = struct {
    reached_trigger_delay: bool = false,
    reached_repeat_rate: bool = false,
};

fn updateInputState(frame: *InputFrame, irm: *InputRepeatManager) !void {
    var i: usize = frame.downs.items.len;
    while (i > 0) {
        i -= 1;
        var code: c_int = @intCast(@intFromEnum(frame.downs.items[i].key));
        if (code < Key.mouse_code_offset) {
            const key: rl.KeyboardKey = @enumFromInt(code);
            if (rl.isKeyUp(key)) {
                try frame.keyUp(frame.downs.items[i].key);
                irm.reached_trigger_delay = false;
                irm.reached_repeat_rate = false;
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonUp(@enumFromInt(code))) {
                try frame.keyUp(frame.downs.items[i].key);
                irm.reached_trigger_delay = false;
                irm.reached_repeat_rate = false;
            }
        }
    }

    for (Key.values) |value| {
        var code: c_int = @intCast(value);
        if (code < Key.mouse_code_offset) {
            if (rl.isKeyDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try frame.keyDown(enum_value, .now);
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try frame.keyDown(enum_value, .now);
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Smooth2DCamera = struct {
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

    fn update(self: *@This()) void {
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
};

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

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}
