const std = @import("std");
const r = @import("raylib");

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
        r.drawText("Congrats! You created your first window!", 190, 200, 20, r.Color.sky_blue);

        const gamepad = 1;

        std.debug.print("is X: {any}\n", .{r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_left)});
        std.debug.print("is A: {any}\n", .{r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_down)});

        var i: i32 = 0;
        const axis_count = r.getGamepadAxisCount(gamepad);
        while (i < axis_count) {
            std.debug.print("axis {d} value: {d}\n", .{ i, r.getGamepadAxisMovement(gamepad, i) });
            i += 1;
        }
    }
}
