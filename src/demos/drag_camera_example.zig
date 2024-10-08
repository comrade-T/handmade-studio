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
    rl.setExitKey(rl.KeyboardKey.key_null);

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

    var ball_position = rl.Vector2{ .x = 0, .y = 0 };
    var ball_target = ball_position;

    var cam_zoom_target = camera.zoom;

    ///////////////////////////// Shader

    var time: f32 = 0;

    const imBlank = rl.genImageColor(screen_height, screen_height, rl.Color.blank);
    const blank_texture = rl.loadTextureFromImage(imBlank);
    rl.unloadImage(imBlank);

    const cube_shader = rl.loadShader(null, "cubes.fs");
    rl.setShaderValue(cube_shader, rl.getShaderLocation(cube_shader, "uTime"), &time, .shader_uniform_float);

    var shader_rec_color = [3]f32{ 0, 0.8, 0.8 };
    rl.setShaderValue(cube_shader, rl.getShaderLocation(cube_shader, "color"), &shader_rec_color, .shader_uniform_vec3);

    ///////////////////////////// Render Texture

    var did_draw_to_render_texture = false;
    const render_texture = rl.loadRenderTexture(screen_height, screen_height);

    const rgb_shader = rl.loadShader(null, "epic_new.frag");
    const resolution = [2]f32{ 512, 512 };
    rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "time"), &time, .shader_uniform_float);
    rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "resolution"), &resolution, .shader_uniform_vec2);

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        { // shader
            time = @floatCast(rl.getTime() / 4);
            rl.setShaderValue(rgb_shader, rl.getShaderLocation(rgb_shader, "time"), &time, .shader_uniform_float);
            rl.setShaderValue(cube_shader, rl.getShaderLocation(cube_shader, "uTime"), &time, .shader_uniform_float);
        }

        {
            if (rl.isMouseButtonPressed(.mouse_button_left)) {
                ball_target.x = if (ball_target.x != 1000) 1000 else 0;
            }
            ball_position = rl.math.vector2Lerp(ball_position, ball_target, 0.05);
        }

        if (rl.isMouseButtonDown(.mouse_button_right)) {
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

                rl.drawRectangle(100, 500, 500, 500, rl.Color.white);

                rl.drawText("Super idol", 100, 100, 60, rl.Color.white);
                rl.drawText("De xiao rong", 100, 200, 60, rl.Color.white);
                rl.drawText("Dou mei ni de tian", 100, 300, 60, rl.Color.white);
                rl.drawText("Ba yue zheng wu de yang guang", 100, 400, 60, rl.Color.white);
            }

            {
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                { // shader stuffs
                    rl.beginShaderMode(cube_shader);
                    defer rl.endShaderMode();
                    rl.drawTexture(blank_texture, 1200, 0, rl.Color.white);
                }

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

                // // draw ball
                // rl.drawCircle(@intFromFloat(ball_position.x), @intFromFloat(ball_position.y), 40, rl.Color.sky_blue);
                //
                // // normal raylib calls
                // rl.drawText("okayge", 100, 100, 30, rl.Color.ray_white);
                // rl.drawCircle(200, 500, 100, rl.Color.yellow);

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

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}
