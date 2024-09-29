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

const initial_screen_width = 1920;
const default_screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// OpenGL Window Initialization

    rl.setConfigFlags(.{ .window_transparent = false, .vsync_hint = true });

    rl.initWindow(initial_screen_width, default_screen_height, "NewMappingMethods");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Camera2D

    var smooth_cam = Smooth2DCamera{};

    var screen_view = ScreenView{
        .width = @as(f32, @floatFromInt(rl.getScreenWidth())),
        .height = @as(f32, @floatFromInt(rl.getScreenHeight())),
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
    try zig_langsuite.initializeQueryMap(gpa);
    try zig_langsuite.initializeNightflyColorscheme(gpa);

    ///////////////////////////// Window

    var buffer = try Buffer.create(gpa, .file, "src/window/window.zig");
    // const source =
    //     \\const ten = 10;
    //     \\fn dummy() void {
    //     \\}
    //     \\pub var x = 0;
    //     \\pub var y = 0;
    // ;
    // var buffer = try Buffer.create(gpa, .string, source);
    try buffer.initiateTreeSitter(zig_langsuite);
    defer buffer.destroy();

    var window = try Window.create(gpa, buffer, .{
        .x = 400,
        .y = 100,
        .render_callbacks = .{
            .drawCodePoint = drawCodePoint,
            .drawRectangle = drawRectangle,

            .camera = &smooth_cam.camera,
            .getMousePositionOnScreen = getMousePositionOnScreen,

            .smooth_cam = &smooth_cam,
            .setSmoothCamTarget = Smooth2DCamera.setTarget,
            .changeTargetXBy = Smooth2DCamera.changeTargetXBy,
            .changeTargetYBy = Smooth2DCamera.changeTargetYBy,
        },
        .assets_callbacks = .{
            .font_manager = font_manager,
            .glyph_callback = fm.FontManager.getGlyphInfo,
            .image_manager = &image_manager,
            .image_callback = ImageManager.getImageSize,
        },
    });
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
        smooth_cam: *Smooth2DCamera,

        fn nop(_: *anyopaque) !void {}
        fn dummy_print(_: *anyopaque) !void {
            std.debug.print("Dumb Dumb\n", .{});
        }

        fn moveCameraTargetUp(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.target_camera.target.y -= 400;
        }
        fn moveCameraTargetDown(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.target_camera.target.y += 400;
        }

        fn moveCameraOffsetUp(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.camera.offset.y -= 400;
        }
        fn moveCameraOffsetDown(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.camera.offset.y += 400;
        }
    };
    var dummy_ctx = DummyCtx{ .smooth_cam = &smooth_cam };
    try council.map("dummy", &.{.p}, .{ .f = DummyCtx.dummy_print, .ctx = &dummy_ctx });

    try council.map("normal", &.{.j}, .{ .f = Window.moveCursorDown, .ctx = window });
    try council.map("normal", &.{.k}, .{ .f = Window.moveCursorUp, .ctx = window });
    try council.map("normal", &.{.h}, .{ .f = Window.moveCursorLeft, .ctx = window });
    try council.map("normal", &.{.l}, .{ .f = Window.moveCursorRight, .ctx = window });
    try council.map("normal", &.{ .left_shift, .six }, .{ .f = Window.moveCursorToBeginningOfLine, .ctx = window });
    try council.map("normal", &.{.zero}, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window });
    try council.map("normal", &.{ .left_shift, .four }, .{ .f = Window.moveCursorToEndOfLine, .ctx = window });
    try council.map("normal", &.{.w}, .{ .f = Window.vimForwardStart, .ctx = window });
    try council.map("normal", &.{.e}, .{ .f = Window.vimForwardEnd, .ctx = window });
    try council.map("normal", &.{.b}, .{ .f = Window.vimBackwardsStart, .ctx = window });

    // Insert Mode
    try window.mapInsertModeCharacters(council);
    try council.map("normal", &.{.i}, .{ .f = DummyCtx.nop, .ctx = &dummy_ctx, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{.a}, .{ .f = Window.enterAFTERInsertMode, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .i }, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .a }, .{ .f = Window.capitalA, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .right_shift, .i }, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .right_shift, .a }, .{ .f = Window.capitalA, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{.o}, .{ .f = Window.vimO, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("insert", &.{.escape}, .{ .f = Window.exitInsertMode, .ctx = window, .contexts = .{ .add = &.{"normal"}, .remove = &.{"insert"} } });
    try council.map("insert", &.{.backspace}, .{ .f = Window.backspace, .ctx = window });

    try council.map("normal", &.{.mouse_button_left}, .{ .f = Window.moveCursorToMouse, .ctx = window });

    // Visual Mode
    try council.map("normal", &.{.v}, .{ .f = Window.enterVisualMode, .ctx = window, .contexts = .{ .add = &.{"visual"}, .remove = &.{"normal"} } });
    try council.map("visual", &.{.escape}, .{ .f = Window.exitVisualMode, .ctx = window, .contexts = .{ .add = &.{"normal"}, .remove = &.{"visual"} } });

    try council.map("visual", &.{.j}, .{ .f = Window.moveCursorDown, .ctx = window });
    try council.map("visual", &.{.k}, .{ .f = Window.moveCursorUp, .ctx = window });
    try council.map("visual", &.{.h}, .{ .f = Window.moveCursorLeft, .ctx = window });
    try council.map("visual", &.{.l}, .{ .f = Window.moveCursorRight, .ctx = window });
    try council.map("visual", &.{ .left_shift, .six }, .{ .f = Window.moveCursorToBeginningOfLine, .ctx = window });
    try council.map("visual", &.{.zero}, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window });
    try council.map("visual", &.{ .left_shift, .four }, .{ .f = Window.moveCursorToEndOfLine, .ctx = window });
    try council.map("visual", &.{.w}, .{ .f = Window.vimForwardStart, .ctx = window });
    try council.map("visual", &.{.e}, .{ .f = Window.vimForwardEnd, .ctx = window });
    try council.map("visual", &.{.b}, .{ .f = Window.vimBackwardsStart, .ctx = window });

    try council.map("visual", &.{.d}, .{ .f = Window.deleteVisualRange, .ctx = window });
    try council.map("visual", &.{.c}, .{ .f = Window.deleteVisualRange, .ctx = window, .contexts = .{ .add = &.{"insert"}, .remove = &.{"visual"} } });

    try council.map("visual", &.{.mouse_button_left}, .{ .f = Window.moveCursorToMouse, .ctx = window });
    try council.map("visual", &.{.o}, .{ .f = Window.swapCursorWithVisualAnchor, .ctx = window });

    // Window Offset Toggle
    try council.map("normal", &.{ .left_shift, .b }, .{ .f = Window.toggleBounds, .ctx = window });

    // Experimental
    try council.map("normal", &.{ .left_control, .u }, .{ .f = DummyCtx.moveCameraTargetUp, .ctx = &dummy_ctx });
    try council.map("normal", &.{ .left_control, .d }, .{ .f = DummyCtx.moveCameraTargetDown, .ctx = &dummy_ctx });
    try council.map("normal", &.{ .left_control, .e }, .{ .f = DummyCtx.moveCameraOffsetUp, .ctx = &dummy_ctx });
    try council.map("normal", &.{ .left_control, .y }, .{ .f = DummyCtx.moveCameraOffsetDown, .ctx = &dummy_ctx });

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Inputs
        try input_repeat_manager.updateInputState();

        // Smooth Camera
        smooth_cam.updateOnNewFrame();
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

                window.render(.{
                    .start = .{ .x = screen_view.start.x, .y = screen_view.start.y },
                    .end = .{ .x = screen_view.end.x, .y = screen_view.end.y },
                });
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn drawRectangle(x: f32, y: f32, width: f32, height: f32, color: u32) void {
    rl.drawRectangle(
        @as(i32, @intFromFloat(x)),
        @as(i32, @intFromFloat(y)),
        @as(i32, @intFromFloat(width)),
        @as(i32, @intFromFloat(height)),
        rl.Color.fromInt(color),
    );
}

fn drawCodePoint(ctx: *anyopaque, code_point: u21, font_face: []const u8, font_size: f32, color: u32, x: f32, y: f32) void {
    const font_manager = @as(*fm.FontManager, @ptrCast(@alignCast(ctx)));
    if (font_manager.fonts.get(font_face)) |mf| {
        rl.drawTextCodepoint(mf.font, @intCast(code_point), .{ .x = x, .y = y }, font_size, rl.Color.fromInt(color));
    }
}

fn getMousePositionOnScreen(camera_: *anyopaque) struct { f32, f32 } {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const mouse = rl.getScreenToWorld2D(rl.getMousePosition(), camera.*);
    return .{ mouse.x, mouse.y };
}

//////////////////////////////////////////////////////////////////////////////////////////////

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

    pub fn update(self: *@This(), camera: rl.Camera2D) void {
        self.start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
        self.end = rl.getScreenToWorld2D(.{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())),
            .y = @as(f32, @floatFromInt(rl.getScreenHeight())),
        }, camera);
        self.width = self.end.x - self.start.x;
        self.height = self.end.y - self.start.y;
    }
};
