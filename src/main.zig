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
        .getWorldToScreen2D = getWorldToScreen2D,
        .getViewFromCamera = getViewFromCamera,
        .cameraTargetsEqual = cameraTargetsEqual,
        .getCameraZoom = getCameraZoom,
    };

    const render_callbacks = RenderMall.RenderCallbacks{
        .drawCodePoint = drawCodePoint,
        .drawRectangle = drawRectangle,
        .drawRectangleLines = drawRectangleLines,
        .drawCircle = drawCircle,
        .drawLine = drawLine,
        .changeCameraZoom = changeCameraZoom,
        .changeCameraPan = changeCameraPan,
        .beginScissorMode = beginScissorMode,
        .endScissorMode = endScissorMode,
    };

    ///////////////////////////// MappingCouncil

    var council = try ip.MappingCouncil.init(gpa);
    defer council.deinit();

    var input_frame = try ip.InputFrame.init(gpa);
    defer input_frame.deinit();

    var input_repeat_manager = InputRepeatManager{ .frame = &input_frame, .council = council };

    try council.setActiveContext("normal");

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

    // WindowManager
    var wm = try WindowManager.create(gpa, &lang_hub, &mall);
    defer wm.destroy();
    try wm.mapKeys(council);

    // AnchorPicker
    var anchor_picker = AnchorPicker{
        .mall = &mall,
        .radius = 20,
        .color = @intCast(rl.Color.sky_blue.toInt()),
        .lerp_time = 0.22,
    };
    anchor_picker.setToCenter();
    try anchor_picker.mapKeys(council);

    // FuzzyFinder
    var fuzzy_finder = try FuzzyFinder.create(gpa, .{ .pos = .{ .x = 100, .y = 100 } }, &mall, wm, &anchor_picker);
    defer fuzzy_finder.destroy();
    try fuzzy_finder.mapKeys(council);

    ///////////////////////////// Normal Mode

    ///////////////////////////// WIP

    try council.map("normal", &.{ .left_control, .left_shift, .p }, .{ .f = WindowManager.saveSession, .ctx = wm });
    try council.map("normal", &.{ .left_shift, .left_control, .p }, .{ .f = WindowManager.saveSession, .ctx = wm });

    try council.map("normal", &.{ .left_control, .left_shift, .l }, .{ .f = WindowManager.loadSession, .ctx = wm });
    try council.map("normal", &.{ .left_shift, .left_control, .l }, .{ .f = WindowManager.loadSession, .ctx = wm });

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
    try council.map("normal", &.{ .left_control, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), wm, &mall, &anchor_picker, .bottom));
    try council.map("normal", &.{ .left_control, .left_shift, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), wm, &mall, &anchor_picker, .right));
    try council.map("normal", &.{ .left_shift, .left_control, .n }, try SpawnBlankWindowCb.init(council.arena.allocator(), wm, &mall, &anchor_picker, .right));

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

fn drawRectangleLines(x: f32, y: f32, width: f32, height: f32, line_thick: f32, color: u32) void {
    rl.drawRectangleLinesEx(
        .{ .x = x, .y = y, .width = width, .height = height },
        line_thick,
        rl.Color.fromInt(color),
    );
}

fn drawCircle(x: f32, y: f32, radius: f32, color: u32) void {
    rl.drawCircleV(.{ .x = x, .y = y }, radius, rl.Color.fromInt(color));
}

fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, color: u32) void {
    rl.drawLineEx(
        .{ .x = start_x, .y = start_y },
        .{ .x = end_x, .y = end_y },
        thickness,
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

fn getWorldToScreen2D(camera_: *anyopaque, x: f32, y: f32) struct { f32, f32 } {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const result = rl.getWorldToScreen2D(.{ .x = x, .y = y }, camera.*);
    return .{ result.x, result.y };
}

fn changeCameraPan(target_camera_: *anyopaque, x_by: f32, y_by: f32) void {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    target_camera.*.target.x += x_by;
    target_camera.*.target.y += y_by;
}

fn getCameraZoom(camera_: *anyopaque) f32 {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    return camera.zoom;
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

fn beginScissorMode(x: f32, y: f32, width: f32, height: f32) void {
    rl.beginScissorMode(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
    );
}

fn endScissorMode() void {
    rl.endScissorMode();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn getScreenWidthHeight() struct { f32, f32 } {
    return .{
        @as(f32, @floatFromInt(rl.getScreenWidth())),
        @as(f32, @floatFromInt(rl.getScreenHeight())),
    };
}
