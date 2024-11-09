const std = @import("std");
const assert = std.debug.assert;

const ztracy = @import("ztracy");
const rl = @import("raylib");

const Smooth2DCamera = @import("raylib-related/Smooth2DCamera.zig");

const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");
const StyleStore = @import("StyleStore");

const LangSuite = @import("LangSuite");
const Window = @import("Window");
const WindowSource = Window.WindowSource;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;
const FONT_BASE_SIZE = 200;

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

    ///////////////////////////// Models

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", FONT_BASE_SIZE, null);
    try addRaylibFontToFontStore(&meslo, "Meslo", &font_store);

    var ws = try WindowSource.init(gpa, .file, "src/outdated/window/old_window.zig", &lang_hub);
    defer ws.deinit();

    const render_callbacks = Window.RenderCallbacks{
        .drawCodePoint = drawCodePoint,
    };

    var window = try Window.create(gpa, &ws, .{
        .pos = .{ .x = 100, .y = 100 },
        .render_callbacks = &render_callbacks,
    }, &style_store);
    defer window.destroy();

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

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

                window.render(&style_store, .{
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

    try store.addNewFont(rl_font, name, FONT_BASE_SIZE);
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
