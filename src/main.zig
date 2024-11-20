const std = @import("std");
const assert = std.debug.assert;

const ztracy = @import("ztracy");
const rl = @import("raylib");

const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");

const ip = @import("input_processor");
const InputRepeatManager = @import("raylib-related/InputRepeatManager.zig");

const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");
const StyleStore = @import("StyleStore");

const LangSuite = @import("LangSuite");
const WindowManager = @import("WindowManager");

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

    var style_store = StyleStore.init(gpa, &font_store, &colorscheme_store);
    defer style_store.deinit();

    // adding custom rules
    try style_store.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 5, // @type
        .styleset_id = 0,
    }, 50);

    try style_store.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 6, // @function
        .styleset_id = 0,
    }, 60);

    try style_store.addFontSizeStyle(.{
        .query_id = 0,
        .capture_id = 0, // @comment
        .styleset_id = 0,
    }, 80);

    ///////////////////////////// Models

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", FONT_BASE_SIZE, null);
    try addRaylibFontToFontStore(&meslo, "Meslo", &font_store);

    var wm = try WindowManager.init(gpa, &lang_hub, &style_store, .{
        .drawCodePoint = drawCodePoint,
        .drawRectangle = drawRectangle,
    });
    defer wm.deinit();

    try wm.spawnWindow(.file, "src/window/fixtures/dummy_3_lines_with_quotes.zig", .{
        .pos = .{ .x = 100, .y = 100 },
        .subscribed_style_sets = &.{0},
    }, true);

    // try wm.spawnWindow(.file, "src/outdated/window/old_window.zig", .{
    //     .pos = .{ .x = 100, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    // }, true);

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

    // TODO: change in word
    // TODO: change in WORD

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

    ///////////////////////////// Insert Mode

    try council.map("normal", &.{.i}, .{ .f = WindowManager.enterInsertMode_i, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{.a}, .{ .f = WindowManager.enterInsertMode_a, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .i }, .{ .f = WindowManager.enterInsertMode_I, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });
    try council.map("normal", &.{ .left_shift, .a }, .{ .f = WindowManager.enterInsertMode_A, .ctx = &wm, .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} } });

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
        fn init(allocator: std.mem.Allocator, target: *WindowManager, chars: []const u8) !ip.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .chars = chars, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };

    const Pair = struct { []const ip.Key, []const u8 };
    const pairs = [_]Pair{
        .{ &.{.a}, "a" },             .{ &.{ .left_shift, .a }, "A" },             .{ &.{ .right_shift, .a }, "A" },
        .{ &.{.b}, "b" },             .{ &.{ .left_shift, .b }, "B" },             .{ &.{ .right_shift, .b }, "B" },
        .{ &.{.c}, "c" },             .{ &.{ .left_shift, .c }, "C" },             .{ &.{ .right_shift, .c }, "C" },
        .{ &.{.d}, "d" },             .{ &.{ .left_shift, .d }, "D" },             .{ &.{ .right_shift, .d }, "D" },
        .{ &.{.e}, "e" },             .{ &.{ .left_shift, .e }, "E" },             .{ &.{ .right_shift, .e }, "E" },
        .{ &.{.f}, "f" },             .{ &.{ .left_shift, .f }, "F" },             .{ &.{ .right_shift, .f }, "F" },
        .{ &.{.g}, "g" },             .{ &.{ .left_shift, .g }, "G" },             .{ &.{ .right_shift, .g }, "G" },
        .{ &.{.h}, "h" },             .{ &.{ .left_shift, .h }, "H" },             .{ &.{ .right_shift, .h }, "H" },
        .{ &.{.i}, "i" },             .{ &.{ .left_shift, .i }, "I" },             .{ &.{ .right_shift, .i }, "I" },
        .{ &.{.j}, "j" },             .{ &.{ .left_shift, .j }, "J" },             .{ &.{ .right_shift, .j }, "J" },
        .{ &.{.k}, "k" },             .{ &.{ .left_shift, .k }, "K" },             .{ &.{ .right_shift, .k }, "K" },
        .{ &.{.l}, "l" },             .{ &.{ .left_shift, .l }, "L" },             .{ &.{ .right_shift, .l }, "L" },
        .{ &.{.m}, "m" },             .{ &.{ .left_shift, .m }, "M" },             .{ &.{ .right_shift, .m }, "M" },
        .{ &.{.n}, "n" },             .{ &.{ .left_shift, .n }, "N" },             .{ &.{ .right_shift, .n }, "N" },
        .{ &.{.o}, "o" },             .{ &.{ .left_shift, .o }, "O" },             .{ &.{ .right_shift, .o }, "O" },
        .{ &.{.p}, "p" },             .{ &.{ .left_shift, .p }, "P" },             .{ &.{ .right_shift, .p }, "P" },
        .{ &.{.q}, "q" },             .{ &.{ .left_shift, .q }, "Q" },             .{ &.{ .right_shift, .q }, "Q" },
        .{ &.{.r}, "r" },             .{ &.{ .left_shift, .r }, "R" },             .{ &.{ .right_shift, .r }, "R" },
        .{ &.{.s}, "s" },             .{ &.{ .left_shift, .s }, "S" },             .{ &.{ .right_shift, .s }, "S" },
        .{ &.{.t}, "t" },             .{ &.{ .left_shift, .t }, "T" },             .{ &.{ .right_shift, .t }, "T" },
        .{ &.{.u}, "u" },             .{ &.{ .left_shift, .u }, "U" },             .{ &.{ .right_shift, .u }, "U" },
        .{ &.{.v}, "v" },             .{ &.{ .left_shift, .v }, "V" },             .{ &.{ .right_shift, .v }, "V" },
        .{ &.{.w}, "w" },             .{ &.{ .left_shift, .w }, "W" },             .{ &.{ .right_shift, .w }, "W" },
        .{ &.{.x}, "x" },             .{ &.{ .left_shift, .x }, "X" },             .{ &.{ .right_shift, .x }, "X" },
        .{ &.{.y}, "y" },             .{ &.{ .left_shift, .y }, "Y" },             .{ &.{ .right_shift, .y }, "Y" },
        .{ &.{.z}, "z" },             .{ &.{ .left_shift, .z }, "Z" },             .{ &.{ .right_shift, .z }, "Z" },
        .{ &.{.one}, "1" },           .{ &.{ .left_shift, .one }, "!" },           .{ &.{ .right_shift, .one }, "!" },
        .{ &.{.two}, "2" },           .{ &.{ .left_shift, .two }, "@" },           .{ &.{ .right_shift, .two }, "@" },
        .{ &.{.three}, "3" },         .{ &.{ .left_shift, .three }, "#" },         .{ &.{ .right_shift, .three }, "#" },
        .{ &.{.four}, "4" },          .{ &.{ .left_shift, .four }, "$" },          .{ &.{ .right_shift, .four }, "$" },
        .{ &.{.five}, "5" },          .{ &.{ .left_shift, .five }, "%" },          .{ &.{ .right_shift, .five }, "%" },
        .{ &.{.six}, "6" },           .{ &.{ .left_shift, .six }, "^" },           .{ &.{ .right_shift, .six }, "^" },
        .{ &.{.seven}, "7" },         .{ &.{ .left_shift, .seven }, "&" },         .{ &.{ .right_shift, .seven }, "&" },
        .{ &.{.eight}, "8" },         .{ &.{ .left_shift, .eight }, "*" },         .{ &.{ .right_shift, .eight }, "*" },
        .{ &.{.nine}, "9" },          .{ &.{ .left_shift, .nine }, "(" },          .{ &.{ .right_shift, .nine }, "(" },
        .{ &.{.zero}, "0" },          .{ &.{ .left_shift, .zero }, ")" },          .{ &.{ .right_shift, .zero }, ")" },
        .{ &.{.minus}, "-" },         .{ &.{ .left_shift, .minus }, "_" },         .{ &.{ .right_shift, .minus }, "_" },
        .{ &.{.equal}, "=" },         .{ &.{ .left_shift, .equal }, "+" },         .{ &.{ .right_shift, .equal }, "+" },
        .{ &.{.comma}, "," },         .{ &.{ .left_shift, .comma }, "<" },         .{ &.{ .right_shift, .comma }, "<" },
        .{ &.{.period}, "." },        .{ &.{ .left_shift, .period }, ">" },        .{ &.{ .right_shift, .period }, ">" },
        .{ &.{.slash}, "/" },         .{ &.{ .left_shift, .slash }, "?" },         .{ &.{ .right_shift, .slash }, "?" },
        .{ &.{.semicolon}, ";" },     .{ &.{ .left_shift, .semicolon }, ":" },     .{ &.{ .right_shift, .semicolon }, ":" },
        .{ &.{.apostrophe}, "'" },    .{ &.{ .left_shift, .apostrophe }, "\"" },   .{ &.{ .right_shift, .apostrophe }, "\"" },
        .{ &.{.backslash}, "\\" },    .{ &.{ .left_shift, .backslash }, "|" },     .{ &.{ .right_shift, .backslash }, "|" },
        .{ &.{.left_bracket}, "[" },  .{ &.{ .left_shift, .left_bracket }, "{" },  .{ &.{ .right_shift, .left_bracket }, "{" },
        .{ &.{.right_bracket}, "]" }, .{ &.{ .left_shift, .right_bracket }, "}" }, .{ &.{ .right_shift, .right_bracket }, "}" },
        .{ &.{.grave}, "`" },         .{ &.{ .left_shift, .grave }, "~" },         .{ &.{ .right_shift, .grave }, "~" },
        .{ &.{.space}, " " },         .{ &.{ .left_shift, .space }, " " },         .{ &.{ .right_shift, .space }, " " },
        .{ &.{.enter}, "\n" },        .{ &.{ .left_shift, .enter }, "\n" },        .{ &.{ .right_shift, .enter }, "\n" },
    };

    for (0..pairs.len) |i| {
        const keys, const chars = pairs[i];
        try council.map("insert", keys, try InsertCharsCb.init(council.arena.allocator(), &wm, chars));
    }

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

                wm.render(.{
                    .start = .{ .x = screen_view.start.x, .y = screen_view.start.y },
                    .end = .{ .x = screen_view.end.x, .y = screen_view.end.y },
                });
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
