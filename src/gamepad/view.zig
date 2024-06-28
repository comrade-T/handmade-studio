const r = @cImport({
    @cInclude("raylib.h");
});
const gamepad_state = @import("state.zig");

const Button = struct {
    is_active: bool = false,

    text: [*c]const u8 = "",
    font_size: c_int = 30,

    active_color: r.struct_Color = r.SKYBLUE,
    inactive_color: r.struct_Color = r.RAYWHITE,

    position_type: enum { relative, absolute } = .relative,
    x: c_int = 0,
    y: c_int = 0,

    rx: c_int = 0,
    ry: c_int = 0,

    // TODO: add `align_x` and `align_y` fields

    fn display(b: *Button) void {
        const x = switch (b.position_type) {
            .relative => b.rx + b.x,
            .absolute => b.x,
        };
        const y = switch (b.position_type) {
            .relative => b.ry + b.y,
            .absolute => b.y,
        };
        const color = if (b.is_active) b.active_color else b.inactive_color;
        r.DrawText(b.text, x, y, b.font_size, color);
    }
};

pub fn drawGamepadState(s: gamepad_state.GamepadState) void {
    const root_LX = 100;
    const root_LY = 200;
    const root_RX = 450;
    const root_RY = 200;

    var left = Button{ .is_active = s.left, .text = "W", .x = -50, .rx = root_LX, .ry = root_LY };
    left.display();
    var right = Button{ .is_active = s.right, .text = "E", .x = 50, .rx = root_LX, .ry = root_LY };
    right.display();
    var up = Button{ .is_active = s.up, .text = "N", .y = -50, .rx = root_LX, .ry = root_LY };
    up.display();
    var down = Button{ .is_active = s.down, .text = "S", .y = 50, .rx = root_LX, .ry = root_LY };
    down.display();

    var btn_x = Button{ .is_active = s.X, .text = "X", .x = -50, .rx = root_RX, .ry = root_RY };
    btn_x.display();
    var btn_b = Button{ .is_active = s.B, .text = "B", .x = 50, .rx = root_RX, .ry = root_RY };
    btn_b.display();
    var btn_y = Button{ .is_active = s.Y, .text = "Y", .y = -50, .rx = root_RX, .ry = root_RY };
    btn_y.display();
    var btn_a = Button{ .is_active = s.A, .text = "A", .y = 50, .rx = root_RX, .ry = root_RY };
    btn_a.display();

    const LT_height = (s.LT + 1) * 50;
    r.DrawRectangle(root_LX - 100, root_LY - 50, 5, @intFromFloat(100), r.RAYWHITE);
    r.DrawRectangle(root_LX - 100, root_LY - 50, 5, @intFromFloat(LT_height), r.SKYBLUE);

    const RT_height = (s.RT + 1) * 50;
    r.DrawRectangle(root_RX + 100, root_RY - 50, 5, @intFromFloat(100), r.RAYWHITE);
    r.DrawRectangle(root_RX + 100, root_RY - 50, 5, @intFromFloat(RT_height), r.SKYBLUE);
}
