const r = @cImport({
    @cInclude("raylib.h");
});

const StickDirection = enum { N, S, E, W, NE, SE, NW, SW, C };

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

pub fn getStickDirection(stick_x: f32, stick_y: f32) StickDirection {
    const threshold = 0.33;
    const LYisCenter = stick_y > -threshold and stick_y < threshold;
    const LXisCenter = stick_x > -threshold and stick_x < threshold;

    if (stick_x < -threshold and LYisCenter) return .W;
    if (stick_x > threshold and LYisCenter) return .E;
    if (stick_y < -threshold and LXisCenter) return .N;
    if (stick_y > threshold and LXisCenter) return .S;

    if (stick_y < -threshold and stick_x > threshold) return .NE;
    if (stick_y > threshold and stick_x > threshold) return .SE;
    if (stick_y < -threshold and stick_x < -threshold) return .NW;
    if (stick_y > threshold and stick_x < -threshold) return .SW;

    return .C;
}

const lowercase_sets = [_][]const u8{ "abcd", "efgh", "ijkl", "mnop", "qrst", "uvwx", "yz12", "3456", "7890" };
const uppercase_sets = [_][]const u8{ "ABCD", "EFGH", "IJKL", "MNOP", "QRST", "UVWX", "YZ!@", "#$%^", "&*()" };
const R3_lowercase_set = "-=[]\\;',.";
const R3_uppercase_set = "_+{}|:\"<>";

pub const L3_character = "/";
pub const L3_uppercase_character = "?";
pub const L3_R3_character = "`";
pub const L3_R3_uppercase_character = "~";

pub fn getSymbolCharacterFromStickDirection(dir: StickDirection, uppercase: bool) u8 {
    const set = if (uppercase) R3_uppercase_set else R3_lowercase_set;
    return switch (dir) {
        .C => set[0],
        .N => set[1],
        .NE => set[2],
        .E => set[3],
        .SE => set[4],
        .S => set[5],
        .SW => set[6],
        .W => set[7],
        .NW => set[8],
    };
}

pub fn getCharacterSetFromStickDirection(dir: StickDirection, uppercase: bool) []const u8 {
    const sets = if (uppercase) uppercase_sets else lowercase_sets;
    return switch (dir) {
        .C => sets[0],
        .N => sets[1],
        .NE => sets[2],
        .E => sets[3],
        .SE => sets[4],
        .S => sets[5],
        .SW => sets[6],
        .W => sets[7],
        .NW => sets[8],
    };
}

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
