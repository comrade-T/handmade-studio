const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

const Bunny = struct {
    position: rl.Vector2,
    speed: rl.Vector2,
    color: rl.Color,
};

pub fn main() !void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "DragCameraExample");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Model

    const texBunny = rl.loadTexture("wabbit_alpha.png");
    defer texBunny.unload();

    const tex_bunny_width: f32 = @floatFromInt(texBunny.width);
    const tex_bunny_height: f32 = @floatFromInt(texBunny.height);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const max_bunnies = 100_000;
    var bunnies = try a.alloc(Bunny, max_bunnies);
    var bunnies_count: usize = 0;

    const font = rl.getFontDefault();

    var scissor_mode = true;
    var scissor_x: i32 = 0;
    var scissor_y: i32 = 0;
    const scissor_width: i32 = 300;
    const scissor_height: i32 = 300;

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        {
            if (rl.isKeyPressed(rl.KeyboardKey.key_s)) scissor_mode = !scissor_mode;
            scissor_x = rl.getMouseX() - scissor_width / 2;
            scissor_y = rl.getMouseY() - scissor_height / 2;
        }

        if (rl.isMouseButtonDown(rl.MouseButton.mouse_button_left)) {
            if (bunnies_count < max_bunnies) {
                for (0..100) |_| {
                    bunnies[bunnies_count].position = rl.getMousePosition();
                    bunnies[bunnies_count].speed.x = @as(f32, @floatFromInt(rl.getRandomValue(-250, 250))) / 60;
                    bunnies[bunnies_count].speed.y = @as(f32, @floatFromInt(rl.getRandomValue(-250, 250))) / 60;
                    bunnies[bunnies_count].color = rl.Color.init(
                        @intCast(rl.getRandomValue(50, 240)),
                        @intCast(rl.getRandomValue(80, 240)),
                        @intCast(rl.getRandomValue(100, 240)),
                        255,
                    );
                    bunnies_count += 1;
                }
            }
        }

        for (0..bunnies_count) |i| {
            bunnies[i].position.x += bunnies[i].speed.x;
            bunnies[i].position.y += bunnies[i].speed.y;

            const px = (bunnies[i].position.x + tex_bunny_width / 2);
            const py = bunnies[i].position.y + tex_bunny_height / 2;

            if (px > screen_width or px < 0) bunnies[i].speed.x *= -1;
            if (py > screen_height or py - 40 < 0) bunnies[i].speed.y *= -1;
        }

        ///////////////////////////// Draw

        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(rl.Color.blank);

            {
                // if (scissor_mode) rl.beginScissorMode(scissor_x, scissor_y, scissor_width, scissor_height);
                // defer if (scissor_mode) rl.endScissorMode();

                for (0..bunnies_count) |i| {
                    // rl.drawTexture(font.texture, @intFromFloat(bunnies[i].position.x), @intFromFloat(bunnies[i].position.y), bunnies[i].color);
                    // rl.drawTexture(texBunny, @intFromFloat(bunnies[i].position.x), @intFromFloat(bunnies[i].position.y), bunnies[i].color);
                    // rl.drawText("a", @intFromFloat(bunnies[i].position.x), @intFromFloat(bunnies[i].position.y), 30, bunnies[i].color);
                    rl.drawTextCodepoint(font, 97, .{ .x = bunnies[i].position.x, .y = bunnies[i].position.y }, 30, bunnies[i].color);
                }
            }

            rl.drawRectangle(0, 0, screen_width, 80, rl.Color.black);
            var buf: [512]u8 = undefined;
            rl.drawText(try std.fmt.bufPrintZ(&buf, "bunnies: {d}", .{bunnies_count}), 120, 10, 40, rl.Color.green);

            rl.drawFPS(10, 10);
        }
    }
}
