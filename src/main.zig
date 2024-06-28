const std = @import("std");
const pretty = @import("pretty");
const r = @cImport({
    @cInclude("raylib.h");
});

const gp_state = @import("gamepad/state.zig");
const gp_view = @import("gamepad/view.zig");

pub fn main() !void {
    const screen_w = 800;
    const screen_h = 450;

    r.InitWindow(screen_w, screen_h, "App");
    defer r.CloseWindow();

    r.SetTargetFPS(60);
    r.SetExitKey(r.KEY_NULL);
    r.SetConfigFlags(r.FLAG_WINDOW_TRANSPARENT);

    while (!r.WindowShouldClose()) {
        r.BeginDrawing();
        defer r.EndDrawing();

        r.ClearBackground(r.BLANK);
        r.DrawText("Congrats! You created your first window!", 190, 50, 20, r.SKYBLUE);

        const gamepad = 1;
        const state = gp_state.getGamepadState(gamepad);

        gp_view.drawGamepadState(state);
    }
}
