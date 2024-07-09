const rl = @import("raylib");

const screen_width = 800;
const screen_height = 450;

pub fn main() anyerror!void {
    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Communism Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.blank);

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.sky_blue);
    }
}
