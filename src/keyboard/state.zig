const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const game = @import("../game.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

pub const KeyboardState = struct {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    d: bool = false,
    e: bool = false,
    f: bool = false,
    g: bool = false,
    h: bool = false,
    i: bool = false,
    j: bool = false,
    k: bool = false,
    l: bool = false,
    m: bool = false,
    n: bool = false,
    o: bool = false,
    p: bool = false,
    q: bool = false,
    r: bool = false,
    s: bool = false,
    t: bool = false,
    u: bool = false,
    v: bool = false,
    w: bool = false,
    x: bool = false,
    y: bool = false,
    z: bool = false,

    one: bool = false,
    two: bool = false,
    three: bool = false,
    four: bool = false,
    five: bool = false,
    six: bool = false,
    seven: bool = false,
    eight: bool = false,
    nine: bool = false,
    zero: bool = false,

    tab: bool = false,
    space: bool = false,
    backspace: bool = false,
    enter: bool = false,

    left_shift: bool = false,
    left_control: bool = false,
    left_alt: bool = false,
    left_super: bool = false,
    right_shift: bool = false,
    right_control: bool = false,
    right_alt: bool = false,
    right_super: bool = false,

    backtick: bool = false,
    minus: bool = false,
    equal: bool = false,
    left_bracket: bool = false,
    right_bracket: bool = false,
    backslash: bool = false,
    semicolon: bool = false,
    single_quote: bool = false,
    comma: bool = false,
    period: bool = false,
    slash: bool = false,
};

pub fn getKeyboardState() KeyboardState {
    return KeyboardState{
        .a = r.IsKeyDown(r.KEY_A),
        .b = r.IsKeyDown(r.KEY_B),
        .c = r.IsKeyDown(r.KEY_C),
        .d = r.IsKeyDown(r.KEY_D),
        .e = r.IsKeyDown(r.KEY_E),
        .f = r.IsKeyDown(r.KEY_F),
        .g = r.IsKeyDown(r.KEY_G),
        .h = r.IsKeyDown(r.KEY_H),
        .i = r.IsKeyDown(r.KEY_I),
        .j = r.IsKeyDown(r.KEY_J),
        .k = r.IsKeyDown(r.KEY_K),
        .l = r.IsKeyDown(r.KEY_L),
        .m = r.IsKeyDown(r.KEY_M),
        .n = r.IsKeyDown(r.KEY_N),
        .o = r.IsKeyDown(r.KEY_O),
        .p = r.IsKeyDown(r.KEY_P),
        .q = r.IsKeyDown(r.KEY_Q),
        .r = r.IsKeyDown(r.KEY_R),
        .s = r.IsKeyDown(r.KEY_S),
        .t = r.IsKeyDown(r.KEY_T),
        .u = r.IsKeyDown(r.KEY_U),
        .v = r.IsKeyDown(r.KEY_V),
        .w = r.IsKeyDown(r.KEY_W),
        .x = r.IsKeyDown(r.KEY_X),
        .y = r.IsKeyDown(r.KEY_Y),
        .z = r.IsKeyDown(r.KEY_Z),

        .one = r.IsKeyDown(r.KEY_ONE),
        .two = r.IsKeyDown(r.KEY_TWO),
        .three = r.IsKeyDown(r.KEY_THREE),
        .four = r.IsKeyDown(r.KEY_FOUR),
        .five = r.IsKeyDown(r.KEY_FIVE),
        .six = r.IsKeyDown(r.KEY_SIX),
        .seven = r.IsKeyDown(r.KEY_SEVEN),
        .eight = r.IsKeyDown(r.KEY_EIGHT),
        .nine = r.IsKeyDown(r.KEY_NINE),
        .zero = r.IsKeyDown(r.KEY_ZERO),

        .tab = r.IsKeyDown(r.KEY_TAB),
        .space = r.IsKeyDown(r.KEY_SPACE),
        .backspace = r.IsKeyDown(r.KEY_BACKSPACE),
        .enter = r.IsKeyDown(r.KEY_ENTER),

        .left_shift = r.IsKeyDown(r.KEY_LEFT_SHIFT),
        .left_control = r.IsKeyDown(r.KEY_LEFT_CONTROL),
        .left_alt = r.IsKeyDown(r.KEY_LEFT_ALT),
        .left_super = r.IsKeyDown(r.KEY_LEFT_SUPER),

        .right_shift = r.IsKeyDown(r.KEY_RIGHT_SHIFT),
        .right_control = r.IsKeyDown(r.KEY_RIGHT_CONTROL),
        .right_alt = r.IsKeyDown(r.KEY_RIGHT_ALT),
        .right_super = r.IsKeyDown(r.KEY_RIGHT_SUPER),

        .backtick = r.IsKeyDown(r.KEY_GRAVE),
        .minus = r.IsKeyDown(r.KEY_MINUS),
        .equal = r.IsKeyDown((r.KEY_EQUAL)),
        .left_bracket = r.IsKeyDown(r.KEY_LEFT_BRACKET),
        .right_bracket = r.IsKeyDown(r.KEY_RIGHT_BRACKET),
        .backslash = r.IsKeyDown(r.KEY_BACKSLASH),
        .semicolon = r.IsKeyDown(r.KEY_SEMICOLON),
        .single_quote = r.IsKeyDown(r.KEY_APOSTROPHE),
        .comma = r.IsKeyDown(r.KEY_COMMA),
        .period = r.IsKeyDown((r.KEY_PERIOD)),
        .slash = r.IsKeyDown(r.KEY_SLASH),
    };
}
