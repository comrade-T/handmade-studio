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

    const distance = 300;

    const points: []const rl.Vector2 = &.{
        .{ .x = distance, .y = distance },
        .{ .x = screen_width - distance, .y = distance },
        .{ .x = distance, .y = screen_height - distance },
        .{ .x = screen_width - distance, .y = screen_height - distance },
    };

    var circle_target = points[0];
    var circle_pos = circle_target;

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        {
            if (rl.isKeyPressed(rl.KeyboardKey.key_u)) circle_target = points[0];
            if (rl.isKeyPressed(rl.KeyboardKey.key_o)) circle_target = points[1];
            if (rl.isKeyPressed(rl.KeyboardKey.key_h)) circle_target = points[2];
            if (rl.isKeyPressed(rl.KeyboardKey.key_l)) circle_target = points[3];
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

            rl.drawText("bonamana", 100, 100, 30, rl.Color.ray_white);
        }
    }
}
