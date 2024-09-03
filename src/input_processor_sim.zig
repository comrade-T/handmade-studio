const std = @import("std");
const rl = @import("raylib");
const _input_processor = @import("input_processor");

const Key = _input_processor.Key;

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

    var vault = try _input_processor.MappingVault.init(a);
    defer vault.deinit();

    {
        try vault.emap(&[_]Key{.j});
        try vault.emap(&[_]Key{.k});
        try vault.emap(&[_]Key{.l});

        try vault.emap(&[_]Key{.a});
        try vault.emap(&[_]Key{ .l, .a });
        try vault.emap(&[_]Key{ .l, .z });
        try vault.emap(&[_]Key{ .l, .z, .c });
    }

    var frame = try _input_processor.InputFrame.init(a);
    defer frame.deinit();

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        {
            var i: usize = frame.downs.items.len;
            while (i > 0) {
                i -= 1;
                const code: c_int = @intCast(@intFromEnum(frame.downs.items[i].key));
                const key: rl.KeyboardKey = @enumFromInt(code);
                if (rl.isKeyUp(key)) {
                    std.debug.print("up it!\n", .{});
                    try frame.keyUp(frame.downs.items[i].key);
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

        {
            if (_input_processor.produceTrigger(
                .editor,
                &frame,
                _input_processor.MappingVault.down_checker,
                _input_processor.MappingVault.up_checker,
                vault,
            )) |trigger| {
                std.debug.print("trigger: 0x{x}\n", .{trigger});
            }
        }

        ///////////////////////////// Draw

        {
            rl.beginDrawing();
            defer rl.endDrawing();

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
