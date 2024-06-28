const std = @import("std");
const pretty = @import("pretty");
const r = @import("raylib");
const gp_state = @import("gamepad/state.zig");
const gp_view = @import("gamepad/view.zig");

pub fn main() anyerror!void {
    const screenWidth = 800;
    const screenHeight = 450;

    r.initWindow(screenWidth, screenHeight, "App");
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
        r.drawText("Congrats! You created your first window!", 190, 50, 20, r.Color.sky_blue);

        const gamepad = 1;
        const state = gp_state.getGamepadState(gamepad);

        gp_view.drawGamepadState(state);

        // try pretty.print(std.heap.c_allocator, state, .{
        //     .struct_max_len = 30,
        // });
    }
}
