const std = @import("std");

const rl = @import("raylib");
const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");
const InputRepeatManager = @import("raylib-related/InputRepeatManager.zig");

const _input_processor = @import("input_processor");
const InputFrame = _input_processor.InputFrame;
const MappingCouncil = _input_processor.MappingCouncil;

const TheList = @import("TheList");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// OpenGL Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "NewMappingMethods");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Camera2D

    var smooth_cam = Smooth2DCamera{};

    ///////////////////////////// General Purpose Allocator

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    ///////////////////////////// MappingCouncil

    var council = try MappingCouncil.init(gpa);
    defer council.deinit();

    ///////////////////////////// InputFrame

    var input_frame = try InputFrame.init(gpa);
    defer input_frame.deinit();

    ///////////////////////////// InputRepeatManager

    // var last_trigger_timestamp: i64 = 0;
    // var last_trigger: u128 = 0;

    var input_repeat_manager = InputRepeatManager{};

    // const trigger_delay = 150;
    // const repeat_rate = 1000 / 62;

    ///////////////////////////// FileNavigator

    var list_items = [_][:0]const u8{ "hello", "from", "the", "other", "side" };
    const the_list = TheList{
        .visible = true,
        .items = &list_items,
        .x = 400,
        .y = 200,
        .line_height = 45,
    };

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Inputs
        try input_repeat_manager.updateInputState(&input_frame);

        // Smooth Camera
        smooth_cam.update();

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            rl.drawFPS(10, 10);

            {
                rl.beginMode2D(smooth_cam.camera);
                defer rl.endMode2D();

                rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);

                // TheList
                {
                    var iter = the_list.iter();
                    while (iter.next()) |r| {
                        const color = if (r.active) rl.Color.sky_blue else rl.Color.ray_white;
                        rl.drawText(r.text, r.x, r.y, r.font_size, color);
                    }
                }
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}
