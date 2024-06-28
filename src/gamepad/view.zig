const std = @import("std");
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
    const root_LX = 150;
    const root_LY = 100;
    const root_RX = 450;
    const root_RY = 100;

    var left = Button{ .is_active = s.left, .text = "W", .x = -50, .rx = root_LX, .ry = root_LY };
    left.display();
    var right = Button{ .is_active = s.right, .text = "E", .x = 50, .rx = root_LX, .ry = root_LY };
    right.display();
    var up = Button{ .is_active = s.up, .text = "N", .y = -50, .rx = root_LX, .ry = root_LY };
    up.display();
    var down = Button{ .is_active = s.down, .text = "S", .y = 50, .rx = root_LX, .ry = root_LY };
    down.display();

    // var btn_x = Button{ .is_active = s.X, .text = "X", .x = -50, .rx = root_RX, .ry = root_RY };
    // btn_x.display();
    // var btn_b = Button{ .is_active = s.B, .text = "B", .x = 50, .rx = root_RX, .ry = root_RY };
    // btn_b.display();
    // var btn_y = Button{ .is_active = s.Y, .text = "Y", .y = -50, .rx = root_RX, .ry = root_RY };
    // btn_y.display();
    // var btn_a = Button{ .is_active = s.A, .text = "A", .y = 50, .rx = root_RX, .ry = root_RY };
    // btn_a.display();

    ////////////////////////////////////////////////////////////////////////////////////////////// LT & RT

    const LT_height = (s.LT + 1) * 50;
    r.DrawRectangle(root_LX - 100, root_LY - 50, 5, @intFromFloat(100), r.RAYWHITE);
    r.DrawRectangle(root_LX - 100, root_LY - 50, 5, @intFromFloat(LT_height), r.SKYBLUE);

    const RT_height = (s.RT + 1) * 50;
    r.DrawRectangle(root_RX + 100, root_RY - 50, 5, @intFromFloat(100), r.RAYWHITE);
    r.DrawRectangle(root_RX + 100, root_RY - 50, 5, @intFromFloat(RT_height), r.SKYBLUE);

    ////////////////////////////////////////////////////////////////////////////////////////////// Stick Directions

    const left_dir = gamepad_state.getStickDirection(s.LX, s.LY);
    var buf: [256]u8 = undefined;
    // var text = std.fmt.bufPrintZ(&buf, "{s}", .{@tagName(left_dir)}) catch "error";
    // r.DrawText(text, root_LX, root_LY + 150, 30, r.RAYWHITE);

    // const right_dir = gamepad_state.getStickDirection(s.RX, s.RY);
    // text = std.fmt.bufPrintZ(&buf, "{s}", .{@tagName(right_dir)}) catch "error";
    // r.DrawText(text, root_RX, root_RY + 150, 30, r.RAYWHITE);

    ////////////////////////////////////////////////////////////////////////////////////////////// Character Sets

    const char_set = gamepad_state.getCharacterSetFromStickDirection(left_dir);
    const char_root_x = root_RX;
    const char_root_y = root_RY;

    const char_x_txt = std.fmt.bufPrintZ(&buf, "{c}", .{char_set[2]}) catch "error";
    var char_x = Button{ .is_active = s.X, .text = char_x_txt, .x = -50, .rx = char_root_x, .ry = char_root_y };
    char_x.display();

    const char_b_txt = std.fmt.bufPrintZ(&buf, "{c}", .{char_set[1]}) catch "error";
    var char_b = Button{ .is_active = s.B, .text = char_b_txt, .x = 50, .rx = char_root_x, .ry = char_root_y };
    char_b.display();

    const char_y_txt = std.fmt.bufPrintZ(&buf, "{c}", .{char_set[3]}) catch "error";
    var char_y = Button{ .is_active = s.Y, .text = char_y_txt, .y = -50, .rx = char_root_x, .ry = char_root_y };
    char_y.display();

    const char_a_txt = std.fmt.bufPrintZ(&buf, "{c}", .{char_set[0]}) catch "error";
    var char_a = Button{ .is_active = s.A, .text = char_a_txt, .y = 50, .rx = char_root_x, .ry = char_root_y };
    char_a.display();
}
