const std = @import("std");
const rl = @import("raylib");
const _input_processor = @import("input_processor");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "InputProcessorSim");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// GPA

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    ///////////////////////////// Model

    var frame = try _input_processor.InputFrame.init(a);
    defer frame.deinit();

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        {
            var previously_down_keys = try std.ArrayList(rl.KeyboardKey).initCapacity(a, frame.downs.items.len);
            defer previously_down_keys.deinit();

            for (frame.downs.items) |e| {
                const code: c_int = @intCast(@intFromEnum(e.key));
                const key: rl.KeyboardKey = @enumFromInt(code);
                try previously_down_keys.append(key);
            }

            for (previously_down_keys.items) |rl_key| {
                if (rl.isKeyUp(rl_key)) {
                    const code: u16 = @intCast(@intFromEnum(rl_key));
                    const key: _input_processor.Key = @enumFromInt(code);
                    try frame.keyUp(key);
                }
            }
        }

        {
            for (_input_processor.Key.values) |value| {
                const code: c_int = @intCast(value);
                if (rl.isKeyDown(@enumFromInt(code))) {
                    const enum_value: _input_processor.Key = @enumFromInt(value);
                    try frame.keyDown(enum_value, .now);
                }
            }
        }

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);

            rl.drawText("kekw", 100, 100, 30, rl.Color.ray_white);
        }
    }
}

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}
