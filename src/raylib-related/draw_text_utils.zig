const std = @import("std");
const rl = @import("raylib");

pub fn drawTextAtBottomRight(
    comptime fmt: []const u8,
    args: anytype,
    font_size: i32,
    screen_width: comptime_int,
    screen_height: comptime_int,
    offset: rl.Vector2,
) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}
