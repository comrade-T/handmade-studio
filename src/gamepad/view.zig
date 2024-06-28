const r = @import("raylib");
const gamepad_state = @import("state.zig");

pub fn drawGamepadState(state: gamepad_state.GamepadState) void {
    const font_size = 40;
    const lx = 200;
    const ly = 250;
    const rx = 500;
    const ry = 250;

    r.drawText("N", lx + 50, ly - 50, font_size, if (state.up) r.Color.blue else r.Color.ray_white);
    r.drawText("S", lx + 50, ly + 50, font_size, if (state.down) r.Color.blue else r.Color.ray_white);
    r.drawText("E", lx + 100, ly, font_size, if (state.right) r.Color.blue else r.Color.ray_white);
    r.drawText("W", lx, ly, font_size, if (state.left) r.Color.blue else r.Color.ray_white);

    r.drawText("X", rx, ry, font_size, if (state.X) r.Color.blue else r.Color.ray_white);
    r.drawText("Y", rx + 50, ry - 50, font_size, if (state.Y) r.Color.blue else r.Color.ray_white);
    r.drawText("A", rx + 50, ry + 50, font_size, if (state.A) r.Color.blue else r.Color.ray_white);
    r.drawText("B", rx + 100, ry, font_size, if (state.B) r.Color.blue else r.Color.ray_white);
}
