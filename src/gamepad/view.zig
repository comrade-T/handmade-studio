const r = @cImport({
    @cInclude("raylib.h");
});
const gamepad_state = @import("state.zig");

pub fn drawGamepadState(state: gamepad_state.GamepadState) void {
    const font_size = 40;
    const lx = 200;
    const ly = 250;
    const rx = 500;
    const ry = 250;

    const active_color = r.BLUE;
    const inactive_color = r.RAYWHITE;

    r.DrawText("N", lx + 50, ly - 50, font_size, if (state.up) active_color else inactive_color);
    r.DrawText("S", lx + 50, ly + 50, font_size, if (state.down) active_color else inactive_color);
    r.DrawText("E", lx + 100, ly, font_size, if (state.right) active_color else inactive_color);
    r.DrawText("W", lx, ly, font_size, if (state.left) active_color else inactive_color);

    r.DrawText("X", rx, ry, font_size, if (state.X) active_color else inactive_color);
    r.DrawText("Y", rx + 50, ry - 50, font_size, if (state.Y) active_color else inactive_color);
    r.DrawText("A", rx + 50, ry + 50, font_size, if (state.A) active_color else inactive_color);
    r.DrawText("B", rx + 100, ry, font_size, if (state.B) active_color else inactive_color);
}
