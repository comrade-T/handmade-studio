const r = @cImport({
    @cInclude("raylib.h");
});

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
        .X = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_FACE_LEFT),
        .Y = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_FACE_UP),
        .A = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_FACE_DOWN),
        .B = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT),

        .up = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_FACE_UP),
        .down = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_FACE_DOWN),
        .left = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_FACE_LEFT),
        .right = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_FACE_RIGHT),

        .LB = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_TRIGGER_1),
        .RB = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_TRIGGER_1),
        .L3 = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_LEFT_THUMB),
        .R3 = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_RIGHT_THUMB),

        .select = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_MIDDLE_LEFT),
        .start = r.IsGamepadButtonDown(gamepad, r.GAMEPAD_BUTTON_MIDDLE_RIGHT),

        .LX = r.GetGamepadAxisMovement(gamepad, 0),
        .LY = r.GetGamepadAxisMovement(gamepad, 1),
        .RX = r.GetGamepadAxisMovement(gamepad, 2),
        .RY = r.GetGamepadAxisMovement(gamepad, 3),
        .LT = r.GetGamepadAxisMovement(gamepad, 4),
        .RT = r.GetGamepadAxisMovement(gamepad, 5),
    };
}
