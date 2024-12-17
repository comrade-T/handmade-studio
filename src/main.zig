const std = @import("std");
const assert = std.debug.assert;

const ztracy = @import("ztracy");
const rl = @import("raylib");

const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");

const ip = @import("input_processor");
const InputRepeatManager = @import("raylib-related/InputRepeatManager.zig");

const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");
const RenderMall = @import("RenderMall");

const LangSuite = @import("LangSuite");
const WindowManager = @import("WindowManager");

const FuzzyFinder = @import("FuzzyFinder");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;
const FONT_BASE_SIZE = 100;

pub fn main() anyerror!void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = false, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "Handmade Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Camera2D

    var smooth_cam = Smooth2DCamera{};
    var screen_view = ScreenView{
        .width = @as(f32, @floatFromInt(rl.getScreenWidth())),
        .height = @as(f32, @floatFromInt(rl.getScreenHeight())),
    };

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ///////////////////////////// Stores

    var font_store = try FontStore.init(gpa);
    defer font_store.deinit();

    var colorscheme_store = try ColorschemeStore.init(gpa);
    defer colorscheme_store.deinit();
    try colorscheme_store.initializeNightflyColorscheme();

    var mall = RenderMall.init(gpa, &font_store, &colorscheme_store);
    defer mall.deinit();

    // adding custom rules
    try mall.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 5, // @type
        .styleset_id = 0,
    }, 50);

    try mall.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 6, // @function
        .styleset_id = 0,
    }, 60);

    try mall.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 0, // @comment
        .styleset_id = 0,
    }, 80);

    ///////////////////////////// render_callbacks

    const render_callbacks = RenderMall.RenderCallbacks{
        .drawCodePoint = drawCodePoint,
        .drawRectangle = drawRectangle,
    };

    ///////////////////////////// Models

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", FONT_BASE_SIZE, null);
    try addRaylibFontToFontStore(&meslo, "Meslo", &font_store);

    var wm = try WindowManager.init(gpa, &lang_hub, &mall, render_callbacks);
    defer wm.deinit();

    ///////////////////////////// Testing

    // try wm.spawnWindow(.file, "src/window/fixtures/dummy_3_lines_with_quotes.zig", .{
    //     .pos = .{ .x = 100, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    // }, true);

    // ------------------------------------

    // // y offset
    //
    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 100, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    //     .bounds = .{
    //         .width = 400,
    //         .height = 300,
    //         .offset = .{ .x = 0, .y = 0 },
    //     },
    // }, true);
    //
    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 600, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    //     .bounds = .{
    //         .width = 400,
    //         .height = 300,
    //         .offset = .{ .x = 0, .y = 100 },
    //     },
    // }, false);
    //
    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 1100, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    //     .bounds = .{
    //         .width = 400,
    //         .height = 300,
    //         .offset = .{ .x = 0, .y = 200 },
    //     },
    // }, false);
    //
    // // x offset
    //
    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 100, .y = 600 },
    //     .subscribed_style_sets = &.{0},
    //     .bounds = .{
    //         .width = 400,
    //         .height = 300,
    //         .offset = .{ .x = 100, .y = 0 },
    //     },
    // }, false);
    //
    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 600, .y = 600 },
    //     .subscribed_style_sets = &.{0},
    //     .bounds = .{
    //         .width = 400,
    //         .height = 300,
    //         .offset = .{ .x = 200, .y = 0 },
    //     },
    // }, false);

    ////////////////////////////////////////////////////////////////////////////////////////////// Inputs

    ///////////////////////////// Setup

    var council = try ip.MappingCouncil.init(gpa);
    defer council.deinit();

    var input_frame = try ip.InputFrame.init(gpa);
    defer input_frame.deinit();

    var input_repeat_manager = InputRepeatManager{ .frame = &input_frame, .council = council };

    ///////////////////////////// Normal Mode

    try council.setActiveContext("normal");

    try council.map("normal", &.{.j}, .{ .f = WindowManager.moveCursorDown, .ctx = &wm });
    try council.map("normal", &.{.k}, .{ .f = WindowManager.moveCursorUp, .ctx = &wm });
    try council.map("normal", &.{.h}, .{ .f = WindowManager.moveCursorLeft, .ctx = &wm });
    try council.map("normal", &.{.l}, .{ .f = WindowManager.moveCursorRight, .ctx = &wm });

    try council.map("normal", &.{.w}, .{ .f = WindowManager.moveCursorForwardWordStart, .ctx = &wm });
    try council.map("normal", &.{.e}, .{ .f = WindowManager.moveCursorForwardWordEnd, .ctx = &wm });
    try council.map("normal", &.{.b}, .{ .f = WindowManager.moveCursorBackwardsWordStart, .ctx = &wm });

    try council.map("normal", &.{ .left_shift, .w }, .{ .f = WindowManager.moveCursorForwardBIGWORDStart, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .e }, .{ .f = WindowManager.moveCursorForwardBIGWORDEnd, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .b }, .{ .f = WindowManager.moveCursorBackwardsBIGWORDStart, .ctx = &wm });

    try council.map("normal", &.{.zero}, .{ .f = WindowManager.moveCursorToFirstNonSpaceCharacterOfLine, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .zero }, .{ .f = WindowManager.moveCursorToBeginningOfLine, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .four }, .{ .f = WindowManager.moveCursorToEndOfLine, .ctx = &wm });

    try council.map("normal", &.{ .d, .p }, .{ .f = WindowManager.debugPrintActiveWindowRope, .ctx = &wm });

    // experimental
    try council.map("normal", &.{ .d, .apostrophe }, .{ .f = WindowManager.deleteInSingleQuote, .ctx = &wm });
    try council.map("normal", &.{ .c, .apostrophe }, .{
        .f = WindowManager.deleteInSingleQuote,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    try council.map("normal", &.{ .d, .semicolon }, .{ .f = WindowManager.deleteInWord, .ctx = &wm });
    try council.map("normal", &.{ .c, .semicolon }, .{
        .f = WindowManager.deleteInWord,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    try council.mapMany("normal", &.{ &.{ .d, .x, .semicolon }, &.{ .x, .d, .semicolon } }, .{ .f = WindowManager.deleteInWORD, .ctx = &wm });
    try council.mapMany("normal", &.{ &.{ .c, .x, .semicolon }, &.{ .x, .c, .semicolon } }, .{
        .f = WindowManager.deleteInWORD,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    ///////////////////////////// Visual Mode

    try council.map("normal", &.{.v}, .{ .f = WindowManager.enterVisualMode, .ctx = &wm, .contexts = .{ .add = &.{"visual"}, .remove = &.{"normal"} } });

    try council.map("visual", &.{.escape}, .{ .f = WindowManager.exitVisualMode, .ctx = &wm, .contexts = .{ .add = &.{"normal"}, .remove = &.{"visual"} } });

    try council.map("visual", &.{.j}, .{ .f = WindowManager.moveCursorDown, .ctx = &wm });
    try council.map("visual", &.{.k}, .{ .f = WindowManager.moveCursorUp, .ctx = &wm });
    try council.map("visual", &.{.h}, .{ .f = WindowManager.moveCursorLeft, .ctx = &wm });
    try council.map("visual", &.{.l}, .{ .f = WindowManager.moveCursorRight, .ctx = &wm });

    try council.map("visual", &.{.w}, .{ .f = WindowManager.moveCursorForwardWordStart, .ctx = &wm });
    try council.map("visual", &.{.e}, .{ .f = WindowManager.moveCursorForwardWordEnd, .ctx = &wm });
    try council.map("visual", &.{.b}, .{ .f = WindowManager.moveCursorBackwardsWordStart, .ctx = &wm });

    try council.map("visual", &.{.d}, .{ .f = WindowManager.delete, .ctx = &wm, .contexts = .{ .add = &.{"normal"}, .remove = &.{"visual"} } });
    try council.map("visual", &.{.c}, .{ .f = WindowManager.delete, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"visual"} } });

    try council.map("visual", &.{ .left_shift, .w }, .{ .f = WindowManager.moveCursorForwardBIGWORDStart, .ctx = &wm });
    try council.map("visual", &.{ .left_shift, .e }, .{ .f = WindowManager.moveCursorForwardBIGWORDEnd, .ctx = &wm });
    try council.map("visual", &.{ .left_shift, .b }, .{ .f = WindowManager.moveCursorBackwardsBIGWORDStart, .ctx = &wm });

    try council.map("visual", &.{.zero}, .{ .f = WindowManager.moveCursorToFirstNonSpaceCharacterOfLine, .ctx = &wm });
    try council.map("visual", &.{ .left_shift, .zero }, .{ .f = WindowManager.moveCursorToBeginningOfLine, .ctx = &wm });
    try council.map("visual", &.{ .left_shift, .four }, .{ .f = WindowManager.moveCursorToEndOfLine, .ctx = &wm });

    ///////////////////////////// Insert Mode

    try council.map("normal", &.{.i}, .{ .f = WindowManager.enterInsertMode_i, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{.a}, .{ .f = WindowManager.enterInsertMode_a, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .i }, .{ .f = WindowManager.enterInsertMode_I, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .a }, .{ .f = WindowManager.enterInsertMode_A, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });

    try council.map("normal", &.{.o}, .{ .f = WindowManager.enterInsertMode_o, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .o }, .{ .f = WindowManager.enterInsertMode_O, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });

    try council.map("insert", &.{ .left_alt, .o }, .{ .f = WindowManager.enterInsertMode_o, .ctx = &wm });
    try council.map("insert", &.{ .left_alt, .left_shift, .o }, .{ .f = WindowManager.enterInsertMode_O, .ctx = &wm });

    try council.map("insert", &.{ .escape, .h }, .{ .f = WindowManager.moveCursorLeft, .ctx = &wm });
    try council.map("insert", &.{ .escape, .j }, .{ .f = WindowManager.moveCursorDown, .ctx = &wm });
    try council.map("insert", &.{ .escape, .k }, .{ .f = WindowManager.moveCursorUp, .ctx = &wm });
    try council.map("insert", &.{ .escape, .l }, .{ .f = WindowManager.moveCursorRight, .ctx = &wm });

    try council.map("insert", &.{.escape}, .{ .f = WindowManager.exitInsertMode, .ctx = &wm, .contexts = .{ .add = &.{"normal"}, .remove = &.{"insert"} } });
    try council.map("insert", &.{.backspace}, .{ .f = WindowManager.backspace, .ctx = &wm });

    try council.map("insert", &.{ .left_control, .p }, .{ .f = WindowManager.debugPrintActiveWindowRope, .ctx = &wm });

    const InsertCharsCb = struct {
        chars: []const u8,
        target: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.insertChars(self.chars);
        }
        fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
            self.* = .{ .chars = chars, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };
    try council.mapInsertCharacters(&.{"insert"}, &wm, InsertCharsCb.init);

    ////////////////////////////////////////////////////////////////////////////////////////////// FuzzyFinder

    var fuzzy_finder = try FuzzyFinder.create(gpa, .{ .pos = .{ .x = 100, .y = 100 } }, &mall, &wm);
    defer fuzzy_finder.destroy();

    try council.mapInsertCharacters(&.{"fuzzy_finder_insert"}, fuzzy_finder, FuzzyFinder.InsertCharsCb.init);
    try council.map("fuzzy_finder_insert", &.{.backspace}, .{ .f = FuzzyFinder.backspace, .ctx = fuzzy_finder });
    try council.map("fuzzy_finder_insert", &.{ .left_control, .j }, .{ .f = FuzzyFinder.nextItem, .ctx = fuzzy_finder });
    try council.map("fuzzy_finder_insert", &.{ .left_control, .k }, .{ .f = FuzzyFinder.prevItem, .ctx = fuzzy_finder });
    try council.map("fuzzy_finder_insert", &.{.enter}, .{
        .f = FuzzyFinder.confirmItemSelection,
        .ctx = fuzzy_finder,
        .contexts = .{ .add = &.{"normal"}, .remove = &.{"fuzzy_finder_insert"} },
    });

    try council.map("normal", &.{ .left_control, .f }, .{
        .f = FuzzyFinder.show,
        .ctx = fuzzy_finder,
        .contexts = .{ .add = &.{"fuzzy_finder_insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

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
            rl.drawFPS(10, 10);
            rl.clearBackground(rl.Color.blank);

            {
                rl.beginMode2D(smooth_cam.camera);
                defer rl.endMode2D();

                { // show borders for testing bounded windows
                    for (wm.wmap.keys()) |window| {
                        if (window.attr.bounded) {
                            rl.drawRectangleV(.{
                                .x = window.attr.pos.x,
                                .y = window.attr.pos.y,
                            }, .{
                                .x = window.attr.bounds.width,
                                .y = window.attr.bounds.height,
                            }, rl.Color.init(255, 255, 255, 30));
                        }
                    }
                }

                const view = RenderMall.ScreenView{
                    .start = .{ .x = screen_view.start.x, .y = screen_view.start.y },
                    .end = .{ .x = screen_view.end.x, .y = screen_view.end.y },
                };

                // rendering windows via WindowManager
                wm.render(view);

                // FuzzyFinder
                fuzzy_finder.render(view, render_callbacks);
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn addRaylibFontToFontStore(rl_font: *rl.Font, name: []const u8, store: *FontStore) !void {
    rl.setTextureFilter(rl_font.texture, .texture_filter_trilinear);

    try store.addNewFont(rl_font, name, FONT_BASE_SIZE, @floatFromInt(rl_font.ascent));
    const f = store.map.getPtr(name) orelse unreachable;
    for (0..@intCast(rl_font.glyphCount)) |i| {
        try f.addGlyph(store.a, rl_font.glyphs[i].value, .{
            .width = rl_font.recs[i].width,
            .offsetX = @as(f32, @floatFromInt(rl_font.glyphs[i].offsetX)),
            .advanceX = @as(f32, @floatFromInt(rl_font.glyphs[i].advanceX)),
        });
    }
}

fn drawCodePoint(font: *const FontStore.Font, code_point: u21, x: f32, y: f32, font_size: f32, color: u32) void {
    assert(font.rl_font != null);
    const rl_font = @as(*rl.Font, @ptrCast(@alignCast(font.rl_font)));
    rl.drawTextCodepoint(rl_font.*, @intCast(code_point), .{ .x = x, .y = y }, font_size, rl.Color.fromInt(color));
}

fn drawRectangle(x: f32, y: f32, width: f32, height: f32, color: u32) void {
    rl.drawRectangle(
        @as(i32, @intFromFloat(x)),
        @as(i32, @intFromFloat(y)),
        @as(i32, @intFromFloat(width)),
        @as(i32, @intFromFloat(height)),
        rl.Color.fromInt(color),
    );
}

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
