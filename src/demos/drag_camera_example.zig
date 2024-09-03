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

    // const font_size = 40;
    // const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

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

                rl.drawText("super idol", 300, 100, 30, rl.Color.ray_white);
                rl.drawText("de xiao rong", 300, 200, 30, rl.Color.ray_white);
            }

            {
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                // draw ball
                rl.drawCircle(@intFromFloat(ball_position.x), @intFromFloat(ball_position.y), 40, rl.Color.sky_blue);

                // normal raylib calls
                rl.drawText("okayge", 100, 100, 30, rl.Color.ray_white);
                rl.drawCircle(200, 500, 100, rl.Color.yellow);

                // texture test
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

                // draw border of original view
                rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);
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

fn printViewInfo(camera: rl.Camera2D) !void {
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

//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////////////

pub const GlyphData = struct {
    value: i32,
    advanceX: i32,
    offsetX: i32,
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const FontData = struct {
    base_size: i32,
    glyph_padding: i32,
    recs: []Rectangle,
    glyphs: []GlyphData,
};

fn saveFontDataToFile(font: rl.Font) !void {
    const a = std.heap.page_allocator;

    var recs = try a.alloc(Rectangle, @intCast(font.glyphCount));
    var glyphs = try a.alloc(GlyphData, @intCast(font.glyphCount));

    for (0..@intCast(font.glyphCount)) |i| {
        recs[i] = Rectangle{
            .x = font.recs[i].x,
            .y = font.recs[i].y,
            .width = font.recs[i].width,
            .height = font.recs[i].height,
        };

        glyphs[i] = GlyphData{
            .advanceX = font.glyphs[i].advanceX,
            .offsetX = @intCast(font.glyphs[i].offsetX),
            .value = font.glyphs[i].value,
        };
    }

    const font_data = FontData{
        .base_size = font.baseSize,
        .glyph_padding = font.glyphPadding,
        .recs = recs,
        .glyphs = glyphs,
    };

    const json_str = try std.json.stringifyAlloc(a, font_data, .{ .whitespace = .indent_4 });
    {
        const file = try std.fs.cwd().createFile("src/window/font_data.json", .{
            .read = true,
            .truncate = true,
        });
        defer file.close();

        _ = try file.writeAll(json_str);

        std.debug.print("\nwritten to font_data.json successfully\n", .{});
    }
}