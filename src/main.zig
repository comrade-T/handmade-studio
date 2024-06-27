const std = @import("std");
const r = @import("raylib");

pub fn main() anyerror!void {
    const screenWidth = 800;
    const screenHeight = 450;

    r.initWindow(screenWidth, screenHeight, "Communism");
    defer r.closeWindow();

    r.setTargetFPS(60);
    r.setExitKey(r.KeyboardKey.key_null);
    r.setConfigFlags(.{
        .window_transparent = true,
    });

    while (!r.windowShouldClose()) {
        r.beginDrawing();
        defer r.endDrawing();

        r.clearBackground(r.Color.blank);
        r.drawText("Congrats! You created your first window!", 190, 200, 20, r.Color.sky_blue);
    }
}
