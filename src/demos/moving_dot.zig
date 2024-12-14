const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "MovingDot");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Model

    const offset = 300;
    const points: []const rl.Vector2 = &.{
        .{ .x = offset, .y = offset },
        .{ .x = screen_width - offset, .y = offset },
        .{ .x = offset, .y = screen_height - offset },
        .{ .x = screen_width - offset, .y = screen_height - offset },
    };

    var circle_target = points[0];
    var circle_pos = circle_target;

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        {
            if (rl.isKeyPressed(rl.KeyboardKey.key_q)) circle_target = points[0];
            if (rl.isKeyPressed(rl.KeyboardKey.key_e)) circle_target = points[1];
            if (rl.isKeyPressed(rl.KeyboardKey.key_z)) circle_target = points[2];
            if (rl.isKeyPressed(rl.KeyboardKey.key_c)) circle_target = points[3];

            const distance = 200;
            if (rl.isKeyPressed(rl.KeyboardKey.key_w)) circle_target.y -= distance;
            if (rl.isKeyPressed(rl.KeyboardKey.key_s)) circle_target.y += distance;
            if (rl.isKeyPressed(rl.KeyboardKey.key_a)) circle_target.x -= distance;
            if (rl.isKeyPressed(rl.KeyboardKey.key_d)) circle_target.x += distance;

            if (rl.isKeyPressed(rl.KeyboardKey.key_x)) circle_target = .{ .x = screen_width / 2, .y = screen_height / 2 };
        }

        {
            circle_pos = rl.math.vector2Lerp(circle_pos, circle_target, 0.2);
        }

        ///////////////////////////// Draw

        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(rl.Color.blank);

            rl.drawCircleV(circle_pos, 20, rl.Color.sky_blue);
        }
    }
}
