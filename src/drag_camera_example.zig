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

    const font_size = 30;
    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

    {
        for (0..@intCast(font.glyphCount)) |i| {
            std.debug.print("i = {d}, char: '{c}', x: {d}, y: {d}, width: {d}, height: {d}\n", .{
                i,
                @as(u8, @intCast(font.glyphs[i].value)),
                font.recs[i].x,
                font.recs[i].y,
                font.recs[i].width,
                font.recs[i].height,
            });
        }

        std.debug.print("glyphPadding {d}\n", .{font.glyphPadding});
    }

    { // testing text stuffs
        std.debug.print("\n================================================================\n", .{});
        defer std.debug.print("================================================================\n\n", .{});
        {
            const measure = rl.measureTextEx(font, "a", 30, 0);
            std.debug.print("measure of char 'a' w/ `Meslo` font -> width: {d} -> height: {d}\n", .{ measure.x, measure.y });
        }
        {
            // if (font.glyphs[index].advanceX != 0) textWidth += font.glyphs[index].advanceX;
            // else textWidth += (font.recs[index].width + font.glyphs[index].offsetX);
            const index: usize = @intCast(rl.getGlyphIndex(font, 'a'));
            const width = if (font.glyphs[index].advanceX != 0)
                @as(f32, @floatFromInt(font.glyphs[index].advanceX))
            else
                font.recs[index].width + @as(f32, @floatFromInt(font.glyphs[index].offsetX));

            std.debug.print("custom measure of char 'a' w/ `Meslo` font -> width: {d} -> height: {d}\n", .{ width, font_size });
        }
        std.debug.print("----------------------------------------------------------------------------------\n", .{});
        {
            const width = rl.measureText("a", 30);
            std.debug.print("measure of char 'a' w/ `default` font -> width: {d} -> height: {d}\n", .{ width, font_size });
        }
    }

    var did_draw_to_render_texture = false;
    const render_texture = rl.loadRenderTexture(1920, 1080);

    ///////////////////////////// Ball

    var ball_position = rl.Vector2{ .x = 0, .y = 0 };
    var ball_target = ball_position;

    var cam_zoom_target = camera.zoom;

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

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

                rl.drawText("super idol", 100, 100, 30, rl.Color.ray_white);
                rl.drawText("de xiao rong", 100, 400, 30, rl.Color.ray_white);
            }

            {
                {
                    rl.beginMode2D(camera);
                    defer rl.endMode2D();

                    { // ball
                        rl.drawCircle(@intFromFloat(ball_position.x), @intFromFloat(ball_position.y), 40, rl.Color.sky_blue);
                    }

                    rl.drawText("okayge", 100, 100, 30, rl.Color.ray_white);
                    rl.drawCircle(200, 500, 100, rl.Color.yellow);

                    const measure = rl.measureTextEx(font, "a", 20, 0);

                    var buf: [1024]u8 = undefined;
                    const txt = try std.fmt.bufPrintZ(&buf, "measure width {d} | height {d}", .{ measure.x, measure.y });
                    rl.drawText(txt, 300, 300, 40, rl.Color.ray_white);

                    rl.drawTextureRec(
                        render_texture.texture,
                        rl.Rectangle{
                            .x = 0,
                            .y = 0,
                            .width = @floatFromInt(render_texture.texture.width),
                            .height = @floatFromInt(-render_texture.texture.height),
                        },
                        .{ .x = 100, .y = 600 },
                        rl.Color.white,
                    );

                    {
                        rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);
                    }
                }

                {
                    const view_start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
                    const view_end = rl.getScreenToWorld2D(.{ .x = screen_width, .y = screen_height }, camera);
                    const view_width = view_end.x - view_start.x;
                    const view_height = view_end.y - view_start.y;

                    try drawTextAtBottomRight(
                        "view_width: {d} | view_height: {d}",
                        .{ view_width, view_height },
                        30,
                        .{ .x = 40, .y = 40 },
                    );

                    try drawTextAtBottomRight(
                        "start_x: {d} | start_y: {d}",
                        .{ view_start.x, view_start.y },
                        30,
                        .{ .x = 40, .y = 100 },
                    );
                }
            }
        }
    }
}

// // Gradually changes a value towards a desired goal over time.
// public static float SmoothDamp(float current, float target, ref float currentVelocity, float smoothTime, [uei.DefaultValue("Mathf.Infinity")]  float maxSpeed, [uei.DefaultValue("Time.deltaTime")]  float deltaTime)
// {
//     // Based on Game Programming Gems 4 Chapter 1.10
//     smoothTime = Mathf.Max(0.0001F, smoothTime);
//     float omega = 2F / smoothTime;
//
//     float x = omega * deltaTime;
//     float exp = 1F / (1F + x + 0.48F * x * x + 0.235F * x * x * x);
//     float change = current - target;
//     float originalTo = target;
//
//     // Clamp maximum speed
//     float maxChange = maxSpeed * smoothTime;
//     change = Mathf.Clamp(change, -maxChange, maxChange);
//     target = current - change;
//
//     float temp = (currentVelocity + omega * change) * deltaTime;
//     currentVelocity = (currentVelocity - omega * temp) * exp;
//     float output = target + (change + temp) * exp;
//
//     // Prevent overshooting
//     if (originalTo - current > 0.0F == output > originalTo)
//     {
//         output = originalTo;
//         currentVelocity = (output - originalTo) / deltaTime;
//     }
//
//     return output;
// }

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
