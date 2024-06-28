const r = @import("raylib");

pub const GamepadState = struct {
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

    LT: f32 = -1,
    RT: f32 = -1,

    LX: f32 = 0,
    LY: f32 = 0,
    RX: f32 = 0,
    RY: f32 = 0,
};

pub fn getGamepadState(gamepad: i32) GamepadState {
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
