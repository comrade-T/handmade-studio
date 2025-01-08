// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

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
const AnchorPicker = @import("AnchorPicker");

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

    var smooth_cam = Smooth2DCamera{ .damp_target = false, .damp_zoom = false };

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ///////////////////////////// render_callbacks

    const info_callbacks = RenderMall.InfoCallbacks{
        .getScreenWidthHeight = getScreenWidthHeight,
        .getScreenToWorld2D = getScreenToWorld2D,
        .getViewFromCamera = getViewFromCamera,
        .cameraTargetsEqual = cameraTargetsEqual,
    };

    const render_callbacks = RenderMall.RenderCallbacks{
        .drawCodePoint = drawCodePoint,
        .drawRectangle = drawRectangle,
        .drawCircle = drawCircle,
        .drawLine = drawLine,
        .changeCameraZoom = changeCameraZoom,
        .changeCameraPan = changeCameraPan,
    };

    ///////////////////////////// Stores

    var font_store = try FontStore.init(gpa);
    defer font_store.deinit();

    var colorscheme_store = try ColorschemeStore.init(gpa);
    defer colorscheme_store.deinit();
    try colorscheme_store.initializeNightflyColorscheme();

    var mall = RenderMall.init(
        gpa,
        &font_store,
        &colorscheme_store,
        info_callbacks,
        render_callbacks,
        &smooth_cam.camera,
        &smooth_cam.target_camera,
    );
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

    ///////////////////////////// Models

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", FONT_BASE_SIZE, null);
    try addRaylibFontToFontStore(&meslo, "Meslo", &font_store);

    var wm = try WindowManager.init(gpa, &lang_hub, &mall);
    defer wm.deinit();

    ///////////////////////////// Testing

    // try wm.spawnWindow(.file, "src/window/fixtures/dummy_3_lines_with_quotes.zig", .{
    //     .pos = .{ .x = 100, .y = 100 },
    //     .subscribed_style_sets = &.{0},
    // }, true);

    // try wm.spawnWindow(.file, "src/window/fixtures/dummy.zig", .{
    //     .pos = .{ .x = 100, .y = 100 },
    //     .limit = .{ .start_line = 3, .end_line = 5 },
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

    // text opjects
    try council.map("normal", &.{ .d, .apostrophe }, .{ .f = WindowManager.deleteInSingleQuote, .ctx = &wm });
    try council.map("normal", &.{ .c, .apostrophe }, .{
        .f = WindowManager.deleteInSingleQuote,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    try council.map("normal", &.{.d}, .{ .f = nop, .ctx = &wm });
    try council.map("normal", &.{.c}, .{ .f = nop, .ctx = &wm });

    try council.map("normal", &.{ .d, .s }, .{ .f = nop2, .ctx = &wm });
    try council.map("normal", &.{ .s, .d }, .{ .f = nop2, .ctx = &wm });

    try council.map("normal", &.{ .c, .x }, .{ .f = nop2, .ctx = &wm });
    try council.map("normal", &.{ .x, .c }, .{ .f = nop2, .ctx = &wm });

    try council.map("normal", &.{ .d, .semicolon }, .{ .f = WindowManager.deleteInWord, .ctx = &wm });
    try council.map("normal", &.{ .c, .semicolon }, .{
        .f = WindowManager.deleteInWord,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    try council.mapMany("normal", &.{ &.{ .d, .s, .semicolon }, &.{ .s, .d, .semicolon } }, .{ .f = WindowManager.deleteInWORD, .ctx = &wm });
    try council.mapMany("normal", &.{ &.{ .c, .x, .semicolon }, &.{ .x, .c, .semicolon } }, .{
        .f = WindowManager.deleteInWORD,
        .ctx = &wm,
        .contexts = .{ .add = &.{"insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    ///////////////////////////// Layout Related

    const CenterAtCb = struct {
        target: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            const center_x: f32 = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
            const center_y: f32 = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;
            self.target.centerAt(center_x, center_y);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("normal", &.{ .left_control, .c }, try CenterAtCb.init(council.arena.allocator(), &wm));

    const MoveByCb = struct {
        target: *WindowManager,
        x: f32,
        y: f32,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.moveBy(self.x, self.y);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, x: f32, y: f32) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .x = x, .y = y };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("normal", &.{ .m, .a }, try MoveByCb.init(council.arena.allocator(), &wm, -100, 0));
    try council.map("normal", &.{ .m, .d }, try MoveByCb.init(council.arena.allocator(), &wm, 100, 0));
    try council.map("normal", &.{ .m, .w }, try MoveByCb.init(council.arena.allocator(), &wm, 0, -100));
    try council.map("normal", &.{ .m, .s }, try MoveByCb.init(council.arena.allocator(), &wm, 0, 100));

    const MakeClosestWindowActiveCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        target: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.makeClosestWindowActive(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, direction: WindowManager.WindowRelativeDirection) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*WindowManager, @ptrCast(@alignCast(ctx)));
            self.* = .{ .direction = direction, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("normal", &.{ .left_control, .h }, try MakeClosestWindowActiveCb.init(council.arena.allocator(), &wm, .left));
    try council.map("normal", &.{ .left_control, .l }, try MakeClosestWindowActiveCb.init(council.arena.allocator(), &wm, .right));
    try council.map("normal", &.{ .left_control, .k }, try MakeClosestWindowActiveCb.init(council.arena.allocator(), &wm, .top));
    try council.map("normal", &.{ .left_control, .j }, try MakeClosestWindowActiveCb.init(council.arena.allocator(), &wm, .bottom));

    ///////////////////////////// WIP

    try council.map("normal", &.{ .left_control, .left_shift, .p }, .{ .f = WindowManager.saveSession, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .left_control, .p }, .{ .f = WindowManager.saveSession, .ctx = &wm });

    try council.map("normal", &.{ .left_control, .left_shift, .l }, .{ .f = WindowManager.loadSession, .ctx = &wm });
    try council.map("normal", &.{ .left_shift, .left_control, .l }, .{ .f = WindowManager.loadSession, .ctx = &wm });

    ////////////////////////////////////////////////////////////////////////////////////////////// Visual Mode

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

    ////////////////////////////////////////////////////////////////////////////////////////////// Insert Mode

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

    ////////////////////////////////////////////////////////////////////////////////////////////// AnchorPicker

    var anchor_picker = AnchorPicker{
        .mall = &mall,
        .radius = 20,
        .color = @intCast(rl.Color.sky_blue.toInt()),
        .lerp_time = 0.22,
    };
    anchor_picker.setToCenter();

    try council.map("normal", &.{ .left_control, .p }, .{
        .f = AnchorPicker.show,
        .ctx = &anchor_picker,
        .contexts = .{ .add = &.{"anchor_picker"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });
    try council.map("anchor_picker", &.{.escape}, .{
        .f = AnchorPicker.hide,
        .ctx = &anchor_picker,
        .contexts = .{ .add = &.{"normal"}, .remove = &.{"anchor_picker"} },
    });

    const AnchorPickerPercentageCb = struct {
        x_percent: f32,
        y_percent: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.percentage(self.x_percent, self.y_percent);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, x_percent: f32, y_percent: f32) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .x_percent = x_percent, .y_percent = y_percent };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };

    try council.map("anchor_picker", &.{ .p, .c }, .{ .f = AnchorPicker.center, .ctx = &anchor_picker });
    try council.map("anchor_picker", &.{ .p, .w }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 50, 25));
    try council.map("anchor_picker", &.{ .p, .s }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 50, 75));
    try council.map("anchor_picker", &.{ .p, .a }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 25, 50));
    try council.map("anchor_picker", &.{ .p, .d }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 75, 50));

    try council.mapUpNDown("normal", &.{ .z, .c }, .{ .down_f = AnchorPicker.show, .up_f = AnchorPicker.hide, .down_ctx = &anchor_picker, .up_ctx = &anchor_picker });
    try council.map("normal", &.{ .z, .c, .m }, .{ .f = AnchorPicker.center, .ctx = &anchor_picker });
    try council.map("normal", &.{ .z, .c, .k }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 50, 25));
    try council.map("normal", &.{ .z, .c, .j }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 50, 75));
    try council.map("normal", &.{ .z, .c, .h }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 25, 50));
    try council.map("normal", &.{ .z, .c, .l }, try AnchorPickerPercentageCb.init(council.arena.allocator(), &anchor_picker, 75, 50));

    ///////////////////////////// Spawn Blank Window

    const SpawnBlankWindowCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        wm: *WindowManager,
        mall: *const RenderMall,
        ap: *const AnchorPicker,

        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

            if (self.wm.active_window == null) {
                const x, const y = info_callbacks.getScreenToWorld2D(
                    self.mall.camera,
                    self.ap.target_anchor.x,
                    self.ap.target_anchor.y,
                );

                try self.wm.spawnWindow(.string, "", .{ .pos = .{ .x = x, .y = y } }, true);
                return;
            }

            try self.wm.spawnNewWindowRelativeToActiveWindow(.string, "", .{}, self.direction);
        }

        pub fn init(
            allocator: std.mem.Allocator,
            wm_: *WindowManager,
            mall_: *const RenderMall,
            ap_: *const AnchorPicker,
            direction: WindowManager.WindowRelativeDirection,
        ) !ip.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .wm = wm_, .mall = mall_, .ap = ap_ };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("normal", &.{ .left_control, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), &wm, &mall, &anchor_picker, .right));
    try council.map("normal", &.{ .left_control, .left_shift, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), &wm, &mall, &anchor_picker, .left));
    try council.map("normal", &.{ .left_shift, .left_control, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), &wm, &mall, &anchor_picker, .left));

    /////////////////////////////

    const AnchorPickerZoomCb = struct {
        scale_factor: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.zoom(self.scale_factor);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, scale_factor: f32, ignore_trigger_delay: bool) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .scale_factor = scale_factor };
            return ip.Callback{ .f = @This().f, .ctx = self, .ignore_trigger_delay = ignore_trigger_delay };
        }
    };

    try council.map("anchor_picker", &.{ .z, .j }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 0.9, true));
    try council.map("anchor_picker", &.{ .z, .k }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 1.1, true));
    try council.map("anchor_picker", &.{ .z, .space, .j }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 0.8, false));
    try council.map("anchor_picker", &.{ .z, .space, .k }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 1.25, false));

    try council.mapUpNDown("normal", &.{ .z, .x }, .{ .down_f = AnchorPicker.show, .up_f = AnchorPicker.hide, .down_ctx = &anchor_picker, .up_ctx = &anchor_picker });
    try council.map("normal", &.{ .z, .x, .j }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 0.8, false));
    try council.map("normal", &.{ .z, .x, .k }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 1.25, false));
    try council.map("normal", &.{ .z, .x, .space, .j }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 0.9, true));
    try council.map("normal", &.{ .z, .x, .space, .k }, try AnchorPickerZoomCb.init(council.arena.allocator(), &anchor_picker, 1.1, true));

    /////////////////////////////

    const AnchorPickerPanCb = struct {
        x_by: f32,
        y_by: f32,
        target: *AnchorPicker,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.target.pan(self.x_by, self.y_by);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, x_by: f32, y_by: f32, ignore_trigger_delay: bool) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*AnchorPicker, @ptrCast(@alignCast(ctx)));
            self.* = .{ .target = target, .x_by = x_by, .y_by = y_by };
            return ip.Callback{
                .f = @This().f,
                .ctx = self,
                .always_trigger_on_down = true,
                .ignore_trigger_delay = ignore_trigger_delay,
            };
        }
    };

    try council.map("normal", &.{ .z, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, false));
    try council.map("normal", &.{ .z, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, false));
    try council.map("normal", &.{ .z, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, false));
    try council.map("normal", &.{ .z, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, false));
    try council.map("normal", &.{ .z, .k, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("normal", &.{ .z, .k, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("normal", &.{ .z, .j, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("normal", &.{ .z, .j, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));
    try council.map("normal", &.{ .z, .h, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("normal", &.{ .z, .h, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("normal", &.{ .z, .l, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("normal", &.{ .z, .l, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));

    try council.map("normal", &.{ .z, .space, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, true));
    try council.map("normal", &.{ .z, .space, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, true));
    try council.map("normal", &.{ .z, .space, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, true));
    try council.map("normal", &.{ .z, .space, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, true));
    try council.map("normal", &.{ .z, .k, .space, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("normal", &.{ .z, .k, .space, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("normal", &.{ .z, .j, .space, .h }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("normal", &.{ .z, .j, .space, .l }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));
    try council.map("normal", &.{ .z, .h, .space, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("normal", &.{ .z, .h, .space, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("normal", &.{ .z, .l, .space, .k }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("normal", &.{ .z, .l, .space, .j }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));

    //

    try council.map("anchor_picker", &.{.w}, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, true));
    try council.map("anchor_picker", &.{.s}, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, true));
    try council.map("anchor_picker", &.{.a}, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, true));
    try council.map("anchor_picker", &.{.d}, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, true));
    try council.map("anchor_picker", &.{ .w, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("anchor_picker", &.{ .s, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("anchor_picker", &.{ .a, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("anchor_picker", &.{ .a, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("anchor_picker", &.{ .w, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("anchor_picker", &.{ .s, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));
    try council.map("anchor_picker", &.{ .d, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("anchor_picker", &.{ .d, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));
    try council.map("anchor_picker", &.{ .space, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, false));
    try council.map("anchor_picker", &.{ .space, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, false));
    try council.map("anchor_picker", &.{ .space, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, false));
    try council.map("anchor_picker", &.{ .space, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, false));
    try council.map("anchor_picker", &.{ .space, .w, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("anchor_picker", &.{ .space, .s, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("anchor_picker", &.{ .space, .a, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("anchor_picker", &.{ .space, .a, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("anchor_picker", &.{ .space, .w, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("anchor_picker", &.{ .space, .s, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));
    try council.map("anchor_picker", &.{ .space, .d, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("anchor_picker", &.{ .space, .d, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));

    try council.map("anchor_picker", &.{ .m, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, true));
    try council.map("anchor_picker", &.{ .m, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, true));
    try council.map("anchor_picker", &.{ .m, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, true));
    try council.map("anchor_picker", &.{ .m, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, true));
    try council.map("anchor_picker", &.{ .m, .w, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("anchor_picker", &.{ .m, .s, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("anchor_picker", &.{ .m, .a, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, true));
    try council.map("anchor_picker", &.{ .m, .a, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, true));
    try council.map("anchor_picker", &.{ .m, .w, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("anchor_picker", &.{ .m, .s, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));
    try council.map("anchor_picker", &.{ .m, .d, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, true));
    try council.map("anchor_picker", &.{ .m, .d, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, true));
    try council.map("anchor_picker", &.{ .m, .space, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, -100, false));
    try council.map("anchor_picker", &.{ .m, .space, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 0, 100, false));
    try council.map("anchor_picker", &.{ .m, .space, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 0, false));
    try council.map("anchor_picker", &.{ .m, .space, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 0, false));
    try council.map("anchor_picker", &.{ .m, .space, .w, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("anchor_picker", &.{ .m, .space, .s, .a }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("anchor_picker", &.{ .m, .space, .a, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, -100, false));
    try council.map("anchor_picker", &.{ .m, .space, .a, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, -100, 100, false));
    try council.map("anchor_picker", &.{ .m, .space, .w, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("anchor_picker", &.{ .m, .space, .s, .d }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));
    try council.map("anchor_picker", &.{ .m, .space, .d, .w }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, -100, false));
    try council.map("anchor_picker", &.{ .m, .space, .d, .s }, try AnchorPickerPanCb.init(council.arena.allocator(), &anchor_picker, 100, 100, false));

    ////////////////////////////////////////////////////////////////////////////////////////////// FuzzyFinder

    var fuzzy_finder = try FuzzyFinder.create(gpa, .{ .pos = .{ .x = 100, .y = 100 } }, &mall, &wm, &anchor_picker);
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

    const RelativeSpawnCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        target: *FuzzyFinder,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.spawnRelativeToActiveWindow(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, direction: WindowManager.WindowRelativeDirection) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*FuzzyFinder, @ptrCast(@alignCast(ctx)));
            self.* = .{ .direction = direction, .target = target };
            return ip.Callback{
                .f = @This().f,
                .ctx = self,
                .contexts = .{ .add = &.{"normal"}, .remove = &.{"fuzzy_finder_insert"} },
            };
        }
    };
    try council.map("fuzzy_finder_insert", &.{ .left_control, .v }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .right));
    try council.map("fuzzy_finder_insert", &.{ .left_control, .left_shift, .v }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .left));
    try council.map("fuzzy_finder_insert", &.{ .left_shift, .left_control, .v }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .left));
    try council.map("fuzzy_finder_insert", &.{ .left_control, .x }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .bottom));
    try council.map("fuzzy_finder_insert", &.{ .left_control, .left_shift, .x }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .top));
    try council.map("fuzzy_finder_insert", &.{ .left_shift, .left_control, .x }, try RelativeSpawnCb.init(council.arena.allocator(), fuzzy_finder, .top));

    try council.map("fuzzy_finder_insert", &.{.escape}, .{
        .f = FuzzyFinder.hide,
        .ctx = fuzzy_finder,
        .contexts = .{ .add = &.{"normal"}, .remove = &.{"fuzzy_finder_insert"} },
    });

    try council.map("normal", &.{ .left_control, .f }, .{
        .f = FuzzyFinder.show,
        .ctx = fuzzy_finder,
        .contexts = .{ .add = &.{"fuzzy_finder_insert"}, .remove = &.{"normal"} },
        .require_clarity_afterwards = true,
    });

    ////////////////////////////////////////////////////////////////////////////////////////////// Connections

    try council.map("normal", &.{ .left_control, .c }, .{
        .f = WindowManager.startPendingConnection,
        .ctx = &wm,
        .contexts = .{ .remove = &.{"normal"}, .add = &.{"pending_connection"} },
    });

    try council.map("pending_connection", &.{.escape}, .{
        .f = WindowManager.cancelPendingConnection,
        .ctx = &wm,
        .contexts = .{ .remove = &.{"pending_connection"}, .add = &.{"normal"} },
    });
    try council.map("pending_connection", &.{.enter}, .{
        .f = WindowManager.confirmPendingConnection,
        .ctx = &wm,
        .contexts = .{ .remove = &.{"pending_connection"}, .add = &.{"normal"} },
    });

    const ChangeConnectionEndWinIDCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        wm: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.wm.switchPendingConnectionEndWindow(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, direction: WindowManager.WindowRelativeDirection) !ip.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .wm = wm_ };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("pending_connection", &.{ .left_control, .h }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), &wm, .left));
    try council.map("pending_connection", &.{ .left_control, .l }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), &wm, .right));
    try council.map("pending_connection", &.{ .left_control, .k }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), &wm, .top));
    try council.map("pending_connection", &.{ .left_control, .j }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), &wm, .bottom));

    const ChangeConnectionAnchorCb = struct {
        const Which = enum { start, end };
        which: Which,
        anchor: WindowManager.Connection.Anchor,
        wm: *WindowManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            if (self.wm.pending_connection == null) return;
            switch (self.which) {
                .start => self.wm.pending_connection.?.start.anchor = self.anchor,
                .end => self.wm.pending_connection.?.end.anchor = self.anchor,
            }
        }
        pub fn init(allocator: std.mem.Allocator, wm_: *WindowManager, which: Which, anchor: WindowManager.Connection.Anchor) !ip.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .which = which, .anchor = anchor, .wm = wm_ };
            return ip.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map("pending_connection", &.{ .s, .h }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .start, .W));
    try council.map("pending_connection", &.{ .s, .l }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .start, .E));
    try council.map("pending_connection", &.{ .s, .k }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .start, .N));
    try council.map("pending_connection", &.{ .s, .j }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .start, .S));
    try council.map("pending_connection", &.{ .e, .h }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .end, .W));
    try council.map("pending_connection", &.{ .e, .l }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .end, .E));
    try council.map("pending_connection", &.{ .e, .k }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .end, .N));
    try council.map("pending_connection", &.{ .e, .j }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), &wm, .end, .S));

    ////////////////////////////////////////////////////////////////////////////////////////////// Debugging

    // const DebugPrintCb = struct {
    //     msg: []const u8,
    //     fn f(ctx: *anyopaque) !void {
    //         const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    //         std.debug.print("{s}\n", .{self.msg});
    //     }
    //     pub fn init(allocator: std.mem.Allocator, msg: []const u8) !ip.Callback {
    //         const self = try allocator.create(@This());
    //         self.* = .{ .msg = msg };
    //         return ip.Callback{ .f = @This().f, .ctx = self };
    //     }
    // };

    /////////////////////////////

    // const UpNDownDebugPrintCb = struct {
    //     up_msg: []const u8,
    //     down_msg: []const u8,
    //     fn up(ctx: *anyopaque) !void {
    //         const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    //         std.debug.print("{s}\n", .{self.up_msg});
    //     }
    //     fn down(ctx: *anyopaque) !void {
    //         const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    //         std.debug.print("{s}\n", .{self.down_msg});
    //     }
    //     pub fn init(allocator: std.mem.Allocator, up_msg: []const u8, down_msg: []const u8) !ip.UpNDownCallback {
    //         const self = try allocator.create(@This());
    //         self.* = .{ .up_msg = up_msg, .down_msg = down_msg };
    //         return ip.UpNDownCallback{
    //             .up_f = @This().up,
    //             .down_f = @This().down,
    //             .up_ctx = self,
    //             .down_ctx = self,
    //         };
    //     }
    // };

    // try council.mapUpNDown("normal", &.{.z}, try UpNDownDebugPrintCb.init(
    //     council.arena.allocator(),
    //     "UpNDownDebugPrintCb: z up",
    //     "UpNDownDebugPrintCb: z down",
    // ));

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // Inputs
        try input_repeat_manager.updateInputState();

        // Smooth Camera
        smooth_cam.updateOnNewFrame();

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.drawFPS(10, 10);
            rl.clearBackground(rl.Color.blank);

            {
                // AnchorPicker
                anchor_picker.render();

                // FuzzyFinder
                fuzzy_finder.render();
            }

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

                // rendering windows via WindowManager
                wm.render();
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

fn drawCircle(x: f32, y: f32, radius: f32, color: u32) void {
    rl.drawCircleV(.{ .x = x, .y = y }, radius, rl.Color.fromInt(color));
}

fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, color: u32) void {
    rl.drawLineV(
        .{ .x = start_x, .y = start_y },
        .{ .x = end_x, .y = end_y },
        rl.Color.fromInt(color),
    );
}

fn changeCameraZoom(camera_: *anyopaque, target_camera_: *anyopaque, x: f32, y: f32, scale_factor: f32) void {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));

    const anchor_world_pos = rl.getScreenToWorld2D(.{ .x = x, .y = y }, camera.*);

    camera.offset = rl.Vector2{ .x = x, .y = y };
    target_camera.offset = rl.Vector2{ .x = x, .y = y };

    target_camera.target = anchor_world_pos;
    camera.target = anchor_world_pos;

    target_camera.zoom = rl.math.clamp(target_camera.zoom * scale_factor, 0.125, 64);
}

fn getScreenToWorld2D(camera_: *anyopaque, x: f32, y: f32) struct { f32, f32 } {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const result = rl.getScreenToWorld2D(.{ .x = x, .y = y }, camera.*);
    return .{ result.x, result.y };
}

fn changeCameraPan(target_camera_: *anyopaque, x_by: f32, y_by: f32) void {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    target_camera.*.target.x += x_by;
    target_camera.*.target.y += y_by;
}

fn getViewFromCamera(camera_: *anyopaque) RenderMall.ScreenView {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera.*);
    const end = rl.getScreenToWorld2D(.{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())),
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())),
    }, camera.*);

    return RenderMall.ScreenView{
        .start = .{ .x = start.x, .y = start.y },
        .end = .{ .x = end.x, .y = end.y },
    };
}

fn cameraTargetsEqual(a_: *anyopaque, b_: *anyopaque) bool {
    const a = @as(*rl.Camera2D, @ptrCast(@alignCast(a_)));
    const b = @as(*rl.Camera2D, @ptrCast(@alignCast(b_)));

    return @round(a.target.x * 100) == @round(b.target.x * 100) and
        @round(a.target.y * 100) == @round(b.target.y * 100);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn getScreenWidthHeight() struct { f32, f32 } {
    return .{
        @as(f32, @floatFromInt(rl.getScreenWidth())),
        @as(f32, @floatFromInt(rl.getScreenHeight())),
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn nop(_: *anyopaque) !void {
    std.debug.print("this is NOP\n", .{});
}

fn nop2(_: *anyopaque) !void {
    std.debug.print("this is NOP 222\n", .{});
}
