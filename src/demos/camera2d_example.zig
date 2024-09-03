const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 800;
const screen_height = 450;

pub fn main() !void {
    ///////////////////////////// Window Initialization

    // rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Camera2DExample");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Try out Camera 2D

    const MAX_BUILDINGS = 100;

    var player = rl.Rectangle{ .x = 400, .y = 280, .width = 40, .height = 40 };
    var buildings: [MAX_BUILDINGS]rl.Rectangle = undefined;
    var buildColors: [MAX_BUILDINGS]rl.Color = undefined;

    var spacing: i32 = 0;
    inline for (0..buildings.len) |i| {
        buildings[i].width = @as(f32, @floatFromInt(rl.getRandomValue(50, 200)));
        buildings[i].height = @as(f32, @floatFromInt(rl.getRandomValue(100, 800)));
        buildings[i].y = screen_height - 130 - buildings[i].height;
        buildings[i].x = @as(f32, @floatFromInt(-6000 + spacing));

        spacing += @as(i32, @intFromFloat(buildings[i].width));

        buildColors[i] = rl.Color.init(
            @as(u8, @intCast(rl.getRandomValue(200, 240))),
            @as(u8, @intCast(rl.getRandomValue(200, 240))),
            @as(u8, @intCast(rl.getRandomValue(200, 250))),
            255,
        );
    }

    var camera = rl.Camera2D{
        .target = rl.Vector2.init(player.x + 20, player.y + 20),
        .offset = rl.Vector2.init(screen_width / 2, screen_height / 2),
        .rotation = 0,
        .zoom = 1,
    };

    ///////////////////////////////// before draw

    while (!rl.windowShouldClose()) {
        {
            // Player movement
            if (rl.isKeyDown(rl.KeyboardKey.key_right)) {
                player.x += 10;
            } else if (rl.isKeyDown(rl.KeyboardKey.key_left)) {
                player.x -= 10;
            }

            // Camera target follows player
            camera.target = rl.Vector2.init(player.x + 20, player.y + 20);

            // Camera rotation controls
            if (rl.isKeyDown(rl.KeyboardKey.key_a)) {
                camera.rotation -= 1;
            } else if (rl.isKeyDown(rl.KeyboardKey.key_s)) {
                camera.rotation += 1;
            }

            // Limit camera rotation to 80 degrees (-40 to 40)
            camera.rotation = rl.math.clamp(camera.rotation, -40, 40);

            // Camera zoom controls
            camera.zoom += rl.getMouseWheelMove() * 0.05;

            camera.zoom = rl.math.clamp(camera.zoom, 0.1, 3.0);

            // Camera reset (zoom and rotation)
            if (rl.isKeyPressed(rl.KeyboardKey.key_r)) {
                camera.zoom = 1.0;
                camera.rotation = 0.0;
            }
        }

        ////////////////////////////////////////////////////////////////////////////////////////////////////// draw

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.ray_white);
        {
            {
                camera.begin();
                defer camera.end();

                rl.drawRectangle(-6000, 320, 13000, 8000, rl.Color.dark_gray);

                for (buildings, 0..) |building, i| {
                    rl.drawRectangleRec(building, buildColors[i]);
                }

                rl.drawRectangleRec(player, rl.Color.red);

                rl.drawLine(
                    @as(i32, @intFromFloat(camera.target.x)),
                    -screen_height * 10,
                    @as(i32, @intFromFloat(camera.target.x)),
                    screen_height * 10,
                    rl.Color.green,
                );
                rl.drawLine(
                    -screen_width * 10,
                    @as(i32, @intFromFloat(camera.target.y)),
                    screen_width * 10,
                    @as(i32, @intFromFloat(camera.target.y)),
                    rl.Color.green,
                );

                rl.drawText("PLAYER", @intFromFloat(player.x), @intFromFloat(player.y), 40, rl.Color.black);
            }

            rl.drawText("SCREEN AREA", 640, 10, 20, rl.Color.red);

            rl.drawRectangle(0, 0, screen_width, 5, rl.Color.red);
            rl.drawRectangle(0, 5, 5, screen_height - 10, rl.Color.red);
            rl.drawRectangle(screen_width - 5, 5, 5, screen_height - 10, rl.Color.red);
            rl.drawRectangle(0, screen_height - 5, screen_width, 5, rl.Color.red);

            rl.drawRectangle(10, 10, 250, 113, rl.Color.sky_blue.fade(0.5));
            rl.drawRectangleLines(10, 10, 250, 113, rl.Color.blue);

            rl.drawText("Free 2d camera controls:", 20, 20, 10, rl.Color.black);
            rl.drawText("- Right/Left to move Offset", 40, 40, 10, rl.Color.dark_gray);
            rl.drawText("- Mouse Wheel to Zoom in-out", 40, 60, 10, rl.Color.dark_gray);
            rl.drawText("- A / S to Rotate", 40, 80, 10, rl.Color.dark_gray);
            rl.drawText("- R to reset Zoom and Rotation", 40, 100, 10, rl.Color.dark_gray);
        }
    }
}
