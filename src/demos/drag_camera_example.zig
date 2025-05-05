const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "DragCameraExample");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.null);

    ///////////////////////////// Model

    var camera = rl.Camera2D{
        .offset = .{ .x = 0, .y = 0 },
        .target = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = 1,
    };

    var current_velocity: f32 = 0;
    const smooth_time = 0.1;
    const max_speed = 40;

    ///////////////////////////// Ball

    var cam_zoom_target = camera.zoom;

    ///////////////////////////// Shader

    var time: f32 = 0;

    var did_draw_to_render_texture = false;
    const render_texture = try rl.loadRenderTexture(screen_height, screen_height);

    const rgb_shader = try rl.loadShader(null, "epic_rainbow.frag");
    const resolution = [2]f32{ screen_width, screen_height };
    rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "time"), &time, .float);
    rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "resolution"), &resolution, .vec3);

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        { // shader
            time = @floatCast(rl.getTime() / 4);
            rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "time"), &time, .float);
        }

        if (rl.isMouseButtonDown(.right)) {
            var delta = rl.getMouseDelta();
            delta = delta.scale(-1 / camera.zoom);
            camera.target = delta.add(camera.target);
        }

        {
            const wheel = rl.getMouseWheelMove();
            if (wheel != 0) {
                const mouse_pos = rl.getMousePosition();
                const mouse_world_pos = rl.getScreenToWorld2D(mouse_pos, camera);
                camera.offset = mouse_pos;
                camera.target = mouse_world_pos;

                var scale_factor = 1 + (0.25 * @abs(wheel));
                if (wheel < 0) scale_factor = 1 / scale_factor;

                cam_zoom_target = rl.math.clamp(cam_zoom_target * scale_factor, 0.125, 64);
            }

            // camera.zoom = rl.math.lerp(camera.zoom, cam_zoom_target, 0.25);
            camera.zoom = smoothDamp(camera.zoom, cam_zoom_target, &current_velocity, smooth_time, max_speed, rl.getFrameTime());
        }

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            rl.drawFPS(10, 10);

            if (!did_draw_to_render_texture) {
                render_texture.begin();
                defer render_texture.end();
                defer did_draw_to_render_texture = true;

                rl.drawRectangle(100, 500, 300, 300, rl.Color.white);

                rl.drawText("Super idol", 100, 100, 60, rl.Color.white);
                rl.drawText("De xiao rong", 100, 200, 60, rl.Color.white);
                rl.drawText("Dou mei ni de tian", 100, 300, 60, rl.Color.white);
                rl.drawText("Ba yue zheng wu de yang guang", 100, 400, 60, rl.Color.white);
            }

            {
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                {
                    rl.beginShaderMode(rgb_shader);
                    defer rl.endShaderMode();

                    rl.drawTextureRec(
                        render_texture.texture,
                        rl.Rectangle{
                            .x = 0,
                            .y = 0,
                            .width = @floatFromInt(render_texture.texture.width),
                            .height = @floatFromInt(-render_texture.texture.height),
                        },
                        .{ .x = 100, .y = 100 },
                        rl.Color.white,
                    );
                }

                // // draw border of original view
                // rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);
            }
        }
    }
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
