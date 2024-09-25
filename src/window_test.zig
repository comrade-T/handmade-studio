const std = @import("std");
const rl = @import("raylib");

const Window = @import("window");
const Buffer = @import("window").Buffer;
const fm = @import("font_manager.zig");
const sitter = @import("ts");

const ip = @import("input_processor");
const InputRepeatManager = @import("raylib-related/InputRepeatManager.zig");

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

    ///////////////////////////// Font Manager & Image Manager

    var font_manager = try fm.FontManager.create(gpa);
    defer font_manager.destroy();

    var image_manager = ImageManager{};

    try font_manager.addFontWithSize("Meslo", "Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 120);

    ///////////////////////////// LangSuite

    var zig_langsuite = try sitter.LangSuite.create(.zig);
    defer zig_langsuite.destroy();
    try zig_langsuite.initializeQueryMap();
    try zig_langsuite.initializeNightflyColorscheme(gpa);

    ///////////////////////////// Window

    var buffer = try Buffer.create(gpa, .file, "build.zig");
    try buffer.initiateTreeSitter(zig_langsuite);
    defer buffer.destroy();

    var window = try Window.create(gpa, buffer, .{ .x = 400, .y = 100 });
    defer window.destroy();

    ///////////////////////////// Inputs

    var council = try ip.MappingCouncil.init(gpa);
    defer council.deinit();

    var input_frame = try ip.InputFrame.init(gpa);
    defer input_frame.deinit();

    var input_repeat_manager = InputRepeatManager{ .frame = &input_frame, .council = council };

    ///////////////////////////// Mappings

    try council.setActiveContext("normal");

    const DummyCtx = struct {
        fn nop(_: *anyopaque) !void {}
        fn dummy_print(_: *anyopaque) !void {
            std.debug.print("Dumb Dumb\n", .{});
        }
    };
    var dummy_ctx = DummyCtx{};
    try council.map("dummy", &.{.p}, .{ .f = DummyCtx.dummy_print, .ctx = &dummy_ctx });

    try council.map("normal", &.{.j}, .{ .f = Window.moveCursorDown, .ctx = window });
    try council.map("normal", &.{.k}, .{ .f = Window.moveCursorUp, .ctx = window });
    try council.map("normal", &.{.h}, .{ .f = Window.moveCursorLeft, .ctx = window });
    try council.map("normal", &.{.l}, .{ .f = Window.moveCursorRight, .ctx = window });

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Inputs
        try input_repeat_manager.updateInputState();

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

                try window.render(
                    .{
                        .start = .{ .x = screen_view.start.x, .y = screen_view.start.y },
                        .end = .{ .x = screen_view.end.x, .y = screen_view.end.y },
                    },
                    .{
                        .drawCodePoint = drawCodePoint,
                    },
                    .{
                        .font_manager = font_manager,
                        .glyph_callback = fm.FontManager.getGlyphInfo,
                        .image_manager = &image_manager,
                        .image_callback = ImageManager.getImageSize,
                    },
                );

                // rl.drawText("hello world", 100, 100, 40, rl.Color.sky_blue);
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn drawCodePoint(ctx: *anyopaque, code_point: u21, font_face: []const u8, font_size: f32, color: u32, x: f32, y: f32) void {
    const font_manager = @as(*fm.FontManager, @ptrCast(@alignCast(ctx)));
    if (font_manager.fonts.get(font_face)) |mf| {
        rl.drawTextCodepoint(mf.font, @intCast(code_point), .{ .x = x, .y = y }, font_size, rl.Color.fromInt(color));
    }
}

const ImageManager = struct {
    fn getImageSize(ctx: *anyopaque, path: []const u8) ?Window.ImageInfo {
        _ = ctx;
        _ = path;
        return Window.ImageInfo{ .width = 100, .height = 100 };
    }
};

const ScreenView = struct {
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
