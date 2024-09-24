const std = @import("std");
const rl = @import("raylib");

const Window = @import("window");
const Buffer = @import("window").Buffer;
const sitter = @import("ts");

const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");

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

    var screen_view = ScreenView{
        .width = screen_width,
        .height = screen_height,
        .screen_width = screen_width,
        .screen_height = screen_height,
    };

    ///////////////////////////// Allocator

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    ///////////////////////////// LangSuite

    var zig_langsuite = try sitter.LangSuite.create(.zig);
    defer zig_langsuite.destroy();
    try zig_langsuite.initializeQueryMap();
    try zig_langsuite.initializeNightflyColorscheme(gpa);

    ///////////////////////////// Window

    var buffer = try Buffer.create(gpa, .string, "hello window");
    try buffer.initiateTreeSitter(zig_langsuite);
    defer buffer.destroy();

    var window = try Window.create(gpa, buffer, .{});
    defer window.destroy();

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Smooth Camera
        smooth_cam.update();
        screen_view.update(smooth_cam.camera);

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            rl.drawFPS(10, 10);

            {
                rl.beginMode2D(smooth_cam.camera);
                defer rl.endMode2D();

                rl.drawText("hello world", 100, 100, 40, rl.Color.sky_blue);
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const ScreenView = struct {
    start: rl.Vector2 = .{ .x = 0, .y = 0 },
    end: rl.Vector2 = .{ .x = 0, .y = 0 },
    width: f32,
    height: f32,
    screen_width: f32,
    screen_height: f32,

    pub fn update(self: *@This(), camera: rl.Camera2D) void {
        self.start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
        self.end = rl.getScreenToWorld2D(.{ .x = self.screen_width, .y = self.screen_height }, camera);
        self.width = self.end.x - self.start.x;
        self.height = self.end.y - self.start.y;
    }
};
