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

const std = @import("std");
const assert = std.debug.assert;

const ztracy = @import("ztracy");
const rl = @import("raylib");
const rlcb = @import("raylib-related/raylib_callbacks.zig");

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
const DepartmentOfInputs = @import("DepartmentOfInputs");

////////////////////////////////////////////////////////////////////////////////////////////// Main //////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = false, .vsync_hint = true, .msaa_4x_hint = true });

    rl.initWindow(screen_width, screen_height, "Handmade Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    var draw_fps = false;

    ///////////////////////////// Camera2D

    var smooth_cam = Smooth2DCamera{ .damp_target = true, .damp_zoom = true };

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ////////////////////////////////////////////////////////////////////////////////////////////// MappingCouncil

    var council = try ip.MappingCouncil.init(gpa);
    defer council.deinit();

    try council.map("normal", &.{.f1}, .{ .f = toggleBool, .ctx = &draw_fps });

    var input_frame = try ip.InputFrame.init(gpa);
    defer input_frame.deinit();

    var input_repeat_manager = InputRepeatManager{ .frame = &input_frame, .council = council };

    try council.setActiveContext("normal");

    ////////////////////////////////////////////////////////////////////////////////////////////// RenderMall

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var font_store = try FontStore.init(gpa);
    defer font_store.deinit();

    var meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", rlcb.FONT_BASE_SIZE, null);
    try rlcb.addRaylibFontToFontStore(&meslo, "Meslo", &font_store);

    var colorscheme_store = try ColorschemeStore.init(gpa);
    defer colorscheme_store.deinit();
    try colorscheme_store.initializeNightflyColorscheme();

    var mall = RenderMall.init(
        gpa,
        &font_store,
        &colorscheme_store,
        rlcb.info_callbacks,
        rlcb.render_callbacks,
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

    ////////////////////////////////////////////////////////////////////////////////////////////// High Level Components

    // AnchorPicker
    var anchor_picker = AnchorPicker{
        .mall = &mall,
        .radius = 20,
        .color = @intCast(rl.Color.sky_blue.toInt()),
        .lerp_time = 0.22,
    };
    anchor_picker.setToCenter();
    try anchor_picker.mapKeys(council);

    // WindowManager
    var wm = try WindowManager.create(gpa, &lang_hub, &mall);
    defer wm.destroy();
    try wm.mapKeys(&anchor_picker, council);

    // FuzzyFinder
    var fuzzy_finder = try FuzzyFinder.create(gpa, .{ .pos = .{ .x = 100, .y = 100 } }, &mall, wm, &anchor_picker);
    defer fuzzy_finder.destroy();
    try fuzzy_finder.mapKeys(council);

    ///////////////////////////// Experimental

    var doi = DepartmentOfInputs{ .a = gpa, .council = council, .mall = &mall };
    defer doi.deinit();

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

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
            rl.clearBackground(rl.Color.blank);
            if (draw_fps) rl.drawFPS(10, 10);

            {
                rl.beginMode2D(smooth_cam.camera);
                defer rl.endMode2D();

                // update windows & render them via WindowManager
                try wm.updateAndRender();
            }

            {
                // AnchorPicker
                anchor_picker.render();

                // FuzzyFinder
                fuzzy_finder.render();
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn toggleBool(ctx: *anyopaque) !void {
    const ptr = @as(*bool, @ptrCast(@alignCast(ctx)));
    ptr.* = !ptr.*;
}
