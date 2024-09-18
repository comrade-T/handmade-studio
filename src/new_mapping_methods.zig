const std = @import("std");
const Allocator = std.mem.Allocator;

const rl = @import("raylib");
const dtu = @import("raylib-related/draw_text_utils.zig");
const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");
const InputRepeatManager = @import("raylib-related/InputRepeatManager.zig");

const _input_processor = @import("input_processor");
const Key = _input_processor.Key;
const InputFrame = _input_processor.InputFrame;
const MappingCouncil = _input_processor.MappingCouncil;

const _vw = @import("virtuous_window");
const Buffer = _vw.Buffer;
const Window = _vw.Window;
const vwr = @import("raylib-related/virtuous_window_related.zig");

const TheList = @import("TheList");

const SmoothDamper = @import("raylib-related/SmoothDamper.zig");

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

    var screen_view = vwr.ScreenView{
        .width = screen_width,
        .height = screen_height,
        .screen_width = screen_width,
        .screen_height = screen_height,
    };

    ///////////////////////////// Allocator

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    ///////////////////////////// Inputs

    var council = try MappingCouncil.init(gpa);
    defer council.deinit();

    var input_frame = try InputFrame.init(gpa);
    defer input_frame.deinit();

    var input_repeat_manager = InputRepeatManager{ .frame = &input_frame, .council = council };

    ///////////////////////////// Experimental - Trying out TheList interaction with MappingCouncil

    var the_list = try TheList.fromHardCodedStrings(gpa, .{
        .x = 400,
        .y = 200,
        .line_height = 45,
    }, &.{ "hello", "from", "the", "other", "side" });
    defer the_list.destroy();

    try council.map("dummy_in_the_list", &[_]Key{.j}, .{ .f = TheList.nextItem, .ctx = the_list });
    try council.map("dummy_in_the_list", &[_]Key{.k}, .{ .f = TheList.prevItem, .ctx = the_list });
    try council.map("dummy_in_the_list", &[_]Key{.r}, .{ .f = TheList.dummyReplace, .ctx = the_list });
    try council.map("dummy_in_the_list", &[_]Key{.q}, .{
        .f = TheList.hide,
        .ctx = the_list,
        .after_trigger = .{
            .contexts_to_remove = &.{"dummy_in_the_list"},
            .contexts_to_add = &.{"dummy"},
        },
    });

    ///////////////////////////// Experimental - Dummy Mappings

    try council.setActiveContext("dummy");

    const DummyCtx = struct {
        council: *MappingCouncil,
        the_list: *TheList,

        smooth_cam: *Smooth2DCamera,
        damper: SmoothDamper = .{},

        screen_view: *vwr.ScreenView,

        fn invu(_: *anyopaque) !void {
            std.debug.print("INVU\n", .{});
        }
        fn in_the_morning(_: *anyopaque) !void {
            std.debug.print("In The Morning\n", .{});
        }
        fn showList(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.the_list.show();
            try self.council.setActiveContext("dummy_in_the_list");
        }
        fn activateWindowMode(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.council.setActiveContext("normal");
        }

        fn moveCameraDown(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.target_camera.target.y += self.screen_view.height / 2;
        }
        fn moveCameraUp(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.smooth_cam.target_camera.target.y -= self.screen_view.height / 2;
        }
        fn updateCamY(self: *@This()) void {
            if (self.smooth_cam.camera.target.y == self.smooth_cam.target_camera.target.y) return;
            self.smooth_cam.camera.target.y = self.damper.damp(
                self.smooth_cam.camera.target.y,
                self.smooth_cam.target_camera.target.y,
                rl.getFrameTime(),
            );
        }

        fn nop(_: *anyopaque) !void {}
    };
    var dummy_ctx = DummyCtx{
        .council = council,
        .the_list = the_list,

        .smooth_cam = &smooth_cam,
        // .damper = .{ .smooth_time = 0.1, .max_speed = 5000 },
        .damper = .{ .smooth_time = 0.1, .max_speed = 8000 },

        .screen_view = &screen_view,
    };

    try council.map("dummy", &[_]Key{.i}, .{ .f = DummyCtx.invu, .ctx = &dummy_ctx });
    try council.map("dummy", &[_]Key{.m}, .{ .f = DummyCtx.in_the_morning, .ctx = &dummy_ctx });
    try council.map("dummy", &[_]Key{.l}, .{ .f = DummyCtx.showList, .ctx = &dummy_ctx });
    try council.map("dummy", &[_]Key{.w}, .{ .f = DummyCtx.activateWindowMode, .ctx = &dummy_ctx });

    ///////////////////////////// Experimental - Trying out Window interactions with MappingCouncil

    // LangSuite
    var zig_langsuite = try _vw.sitter.LangSuite.create(.zig);
    defer zig_langsuite.destroy();
    try zig_langsuite.initializeQuery();
    try zig_langsuite.initializeFilter(gpa);
    try zig_langsuite.initializeNightflyColorscheme(gpa);

    // Buffer
    var buf = try Buffer.create(gpa, .file, "build.zig");
    try buf.initiateTreeSitter(zig_langsuite);
    defer buf.destroy();

    // Font

    const font_size = 40;
    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

    const font_data = try vwr.generateFontData(gpa, font);
    defer gpa.free(font_data.recs);
    defer gpa.free(font_data.glyphs);

    var font_data_index_map = try _vw.createFontDataIndexMap(gpa, font_data);
    defer font_data_index_map.deinit();

    // Window
    var window = try Window.spawn(gpa, buf, .{ .font_size = font_size, .x = 400, .y = 100 });
    defer window.destroy();

    ///////////////////////////// Mappings

    try council.map("normal", &[_]Key{.j}, .{ .f = Window.moveCursorDown, .ctx = window });
    try council.map("normal", &[_]Key{.k}, .{ .f = Window.moveCursorUp, .ctx = window });
    try council.map("normal", &[_]Key{.h}, .{ .f = Window.moveCursorLeft, .ctx = window });
    try council.map("normal", &[_]Key{.l}, .{ .f = Window.moveCursorRight, .ctx = window });

    try council.map("normal", &[_]Key{.zero}, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window });
    try council.map("normal", &[_]Key{ .left_shift, .four }, .{ .f = Window.moveCursorToEndOfLine, .ctx = window });
    try council.map("normal", &[_]Key{ .right_shift, .four }, .{ .f = Window.moveCursorToEndOfLine, .ctx = window });
    try council.map("normal", &[_]Key{ .left_shift, .zero }, .{ .f = Window.moveCursorToBeginningOfLine, .ctx = window });
    try council.map("normal", &[_]Key{ .right_shift, .zero }, .{ .f = Window.moveCursorToBeginningOfLine, .ctx = window });

    try council.map("normal", &[_]Key{.escape}, .{ .f = DummyCtx.nop, .ctx = &dummy_ctx, .after_trigger = .{
        .contexts_to_remove = &.{"normal"},
        .contexts_to_add = &.{"dummy"},
    } });

    try council.map("normal", &[_]Key{.w}, .{ .f = Window.vimForwardStart, .ctx = window });
    try council.map("normal", &[_]Key{.e}, .{ .f = Window.vimForwardEnd, .ctx = window });
    try council.map("normal", &[_]Key{.b}, .{ .f = Window.vimBackwardsStart, .ctx = window });

    try council.map("normal", &[_]Key{ .left_control, .u }, .{ .f = DummyCtx.moveCameraUp, .ctx = &dummy_ctx });
    try council.map("normal", &[_]Key{ .left_control, .d }, .{ .f = DummyCtx.moveCameraDown, .ctx = &dummy_ctx });

    // Part 2
    try council.map("normal", &[_]Key{.i}, .{ .f = DummyCtx.nop, .ctx = &dummy_ctx, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });
    try council.map("normal", &[_]Key{.a}, .{ .f = Window.enterAFTERInsertMode, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });

    try council.map("normal", &[_]Key{ .left_shift, .i }, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });
    try council.map("normal", &[_]Key{ .left_shift, .a }, .{ .f = Window.capitalA, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });
    try council.map("normal", &[_]Key{ .right_shift, .i }, .{ .f = Window.moveCursorToFirstNonBlankChar, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });
    try council.map("normal", &[_]Key{ .right_shift, .a }, .{ .f = Window.capitalA, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"insert"},
        .contexts_to_remove = &.{"normal"},
    } });

    try window.mapInsertModeCharacters(council);

    try council.map("insert", &[_]Key{.escape}, .{ .f = Window.exitInsertMode, .ctx = window, .after_trigger = .{
        .contexts_to_add = &.{"normal"},
        .contexts_to_remove = &.{"insert"},
    } });

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Inputs
        try input_repeat_manager.updateInputState();

        // Smooth Camera
        smooth_cam.update();
        screen_view.update(smooth_cam.camera);
        dummy_ctx.updateCamY();

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            rl.drawFPS(10, 10);

            {
                rl.beginMode2D(smooth_cam.camera);
                defer rl.endMode2D();

                // rl.drawRectangleLines(0, 0, screen_width, screen_height, rl.Color.sky_blue);

                vwr.renderVirtuousWindow(window, font, font_size, font_data, font_data_index_map, screen_view);
            }

            // TheList
            if (the_list.is_visible) {
                var iter = the_list.iter();
                while (iter.next()) |r| {
                    const color = if (r.active) rl.Color.sky_blue else rl.Color.ray_white;
                    try dtu.drawTextAlloc(gpa, "{s}", .{r.text}, r.x, r.y, r.font_size, color);
                }
            }
        }
    }
}
