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
const builtin = @import("builtin");
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
const Session = @import("Session");
const LSPClientManager = @import("LSPClientManager");

const fuzzy_finders = @import("fuzzy_finders");
const AnchorPicker = @import("AnchorPicker");
const DepartmentOfInputs = @import("DepartmentOfInputs");

const ConfirmationPrompt = @import("ConfirmationPrompt");
const NotificationLine = @import("NotificationLine");

const ManWhoHidesTheCursor = @import("raylib-related/ManWhoHidesTheCursor.zig");

////////////////////////////////////////////////////////////////////////////////////////////// Main //////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {
    const startup_ztracy_zone = ztracy.ZoneNC(@src(), "START UP", 0x00AAFF);

    ///////////////////////////// Window Initialization

    const rl_initwindow_zone = ztracy.ZoneNC(@src(), "raylib initWindow()", 0xAABBFF);
    const window_resizable = comptime if (builtin.mode == .Debug) false else true;

    rl.setConfigFlags(.{
        .window_transparent = false,
        .vsync_hint = true,
        .msaa_4x_hint = true,
        .window_resizable = window_resizable,
    });

    rl.initWindow(screen_width, screen_height, "Handmade Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.null);

    rl_initwindow_zone.End();

    var draw_fps = false;

    ///////////////////////////// ManWhoHidesTheCursor

    var man_who_hides_the_cursor = ManWhoHidesTheCursor{ .show_duration_ms = 750 };

    ///////////////////////////// Camera2D

    var smooth_cam = Smooth2DCamera{ .damp_target = true, .damp_zoom = true };

    ///////////////////////////// GPA

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

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

    var meslo = try rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", rlcb.FONT_BASE_SIZE, null);
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

    // TODO: add #priority directive to QueryFilter

    // try mall.addFontSizeStyle(.{
    //     .query_id = 0,
    //     .capture_id = 2, // @type
    //     .styleset_id = 0,
    // }, 50);

    // try mall.addFontSizeStyle(.{
    //     .query_id = 0,
    //     .capture_id = 6, // @function
    //     .styleset_id = 0,
    // }, 60);

    // try mall.addFontSizeStyle(.{
    //     .query_id = 0,
    //     .capture_id = 0, // @comment
    //     .styleset_id = 0,
    // }, 80);

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

    // DepartmentOfInputs
    var doi = DepartmentOfInputs{ .a = gpa, .council = council, .mall = &mall };
    defer doi.deinit();

    // ConfirmationPrompt
    var confirmation_prompt = ConfirmationPrompt{ .a = gpa, .council = council, .mall = &mall };
    try confirmation_prompt.mapKeys();
    defer confirmation_prompt.deinit();

    // NotificationLine
    var notification_line = NotificationLine{ .a = gpa, .mall = &mall };
    defer notification_line.deinit();

    // LSPClientManager
    var lspman = LSPClientManager{ .a = gpa };
    defer lspman.deinit();

    // Session
    var session = Session{
        .a = gpa,

        .lang_hub = &lang_hub,
        .mall = &mall,
        .nl = &notification_line,
        .cp = &confirmation_prompt,

        .ap = &anchor_picker,
        .council = council,
        .lspman = &lspman,
    };
    defer session.deinit();
    try session.mapKeys();
    _ = try session.newCanvas(); // create empty canvas on startup

    // FuzzyFinder
    var fuzzy_file_opener = try fuzzy_finders.FuzzyFileOpener.create(gpa, &session, &anchor_picker, &doi, &confirmation_prompt, &notification_line);
    defer fuzzy_file_opener.destroy();

    var fuzzy_session_opener = try fuzzy_finders.FuzzySessionOpener.create(gpa, &session, &doi, &confirmation_prompt, &notification_line);
    defer fuzzy_session_opener.destroy();

    var fuzzy_session_savior = try fuzzy_finders.FuzzySessionSavior.create(gpa, &session, &doi, &confirmation_prompt, &notification_line);
    defer fuzzy_session_savior.destroy();

    var fuzzy_entity_picker = try fuzzy_finders.FuzzyEntityPicker.create(gpa, &session, &doi);
    defer fuzzy_entity_picker.destroy();

    var fuzzy_string_window_jumper = try fuzzy_finders.FuzzyStringWindowJumper.create(gpa, &session, &doi);
    defer fuzzy_string_window_jumper.destroy();

    startup_ztracy_zone.End();

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    const TIME_TO_CLOSE_MS = 0 * 1_000;
    const TIME_TO_CLOSE = TIME_TO_CLOSE_MS * 1_000_000;
    var timestamp_to_close: ?i128 = null;
    var time_to_close_sec: i128 = 0;

    while (true) {
        if (rl.windowShouldClose()) timestamp_to_close = std.time.nanoTimestamp() + TIME_TO_CLOSE;
        if (timestamp_to_close) |close_time| {
            if (std.time.nanoTimestamp() > close_time) break;
            const num = @divFloor(close_time - std.time.nanoTimestamp(), 1_000_000 * 1_000) + 1;
            if (num != time_to_close_sec) std.debug.print("{d} sec until program close\n", .{num});
            time_to_close_sec = num;
        }

        ///////////////////////////// Update

        // Inputs
        const executed_a_mapping = try input_repeat_manager.updateInputState();
        if (executed_a_mapping) notification_line.clearIfDurationMet();

        // Smooth Camera
        smooth_cam.updateOnNewFrame();

        // ManWhoHidesTheCursor
        man_who_hides_the_cursor.update();

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
                try session.updateAndRender();
            }

            { // Experimental
                session.experimental_minimap.render(&session);
            }

            {
                // AnchorPicker
                anchor_picker.render();

                // fuzzy_finders
                fuzzy_file_opener.finder.render();
                fuzzy_session_opener.finder.render();
                fuzzy_session_savior.ffc.finder.render();
                fuzzy_entity_picker.finder.render();
                fuzzy_string_window_jumper.finder.render();

                // NotificationLine
                notification_line.render();

                // ConfirmationPrompt
                confirmation_prompt.render();

                // DepartmentOfInputs
                doi.render();
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn toggleBool(ctx: *anyopaque) !void {
    const ptr = @as(*bool, @ptrCast(@alignCast(ctx)));
    ptr.* = !ptr.*;
}
