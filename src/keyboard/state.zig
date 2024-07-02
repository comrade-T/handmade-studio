const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const game = @import("../game.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const codes = [_]c_int{
    r.KEY_A,
    r.KEY_B,
    r.KEY_C,
    r.KEY_D,
    r.KEY_E,
    r.KEY_F,
    r.KEY_G,
    r.KEY_H,
    r.KEY_I,
    r.KEY_J,
    r.KEY_K,
    r.KEY_L,
    r.KEY_M,
    r.KEY_N,
    r.KEY_O,
    r.KEY_P,
    r.KEY_Q,
    r.KEY_R,
    r.KEY_S,
    r.KEY_T,
    r.KEY_U,
    r.KEY_V,
    r.KEY_W,
    r.KEY_X,
    r.KEY_Y,
    r.KEY_Z,
};

pub fn updateKeyMap(map: *std.AutoHashMap(c_int, bool)) !void {
    for (codes) |code| {
        if (r.IsKeyDown(code)) {
            try map.put(code, true);
        }
        if (r.IsKeyUp(code)) {
            _ = map.remove(code);
        }
    }
}
