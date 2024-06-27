const std = @import("std");
const r = @import("raylib");

const GamepadState = struct {
    X: bool = false,
    A: bool = false,
    Y: bool = false,
    B: bool = false,

    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    LB: bool = false,
    RB: bool = false,
    L3: bool = false,
    R3: bool = false,

    select: bool = false,
    start: bool = false,

    LT: f32 = 0,
    RT: f32 = 0,

    LX: f32 = 0,
    LY: f32 = 0,
    RX: f32 = 0,
    RY: f32 = 0,
};

fn getGamepadState(gamepad: i32) GamepadState {
    return GamepadState{
        .X = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_left),
        .Y = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_up),
        .A = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_down),
        .B = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_face_right),

        .up = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_face_up),
        .down = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_face_down),
        .left = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_face_left),
        .right = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_face_right),

        .LB = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_trigger_1),
        .RB = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_trigger_1),
        .L3 = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_left_thumb),
        .R3 = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_right_thumb),

        .select = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_middle_left),
        .start = r.isGamepadButtonDown(gamepad, r.GamepadButton.gamepad_button_middle_right),

        .LX = r.getGamepadAxisMovement(gamepad, 0),
        .LY = r.getGamepadAxisMovement(gamepad, 1),
        .RX = r.getGamepadAxisMovement(gamepad, 2),
        .RY = r.getGamepadAxisMovement(gamepad, 3),
        .LT = r.getGamepadAxisMovement(gamepad, 4),
        .RT = r.getGamepadAxisMovement(gamepad, 5),
    };
}

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
        const gamepad_state = getGamepadState(gamepad);

        std.debug.print("{any}\n", .{gamepad_state});
    }
}
