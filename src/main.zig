const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const LangSuite = @import("LangSuite");
const FontStore = @import("FontStore");

const Window = @import("Window");
const WindowSource = Window.WindowSource;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Handmade Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ///////////////////////////// Models

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var font_store = try FontStore.init(gpa);
    defer font_store.deinit();

    const meslo_base_size = 40;
    const meslo = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", meslo_base_size, null);
    try addRaylibFontToFontStore(meslo, "Meslo", meslo_base_size, &font_store);

    var ws = try WindowSource.init(gpa, .file, "src/outdated/window/old_window.zig", &lang_hub);
    defer ws.deinit();

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.drawFPS(10, 10);
            rl.clearBackground(rl.Color.blank);

            rl.drawTextEx(meslo, "hello handsome", .{ .x = 100, .y = 100 }, meslo_base_size, 0, rl.Color.ray_white);
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn addRaylibFontToFontStore(rl_font: rl.Font, name: []const u8, base_size: f32, store: *FontStore) !void {
    try store.addNewFont(name, base_size);
    const f = store.map.getPtr(name) orelse unreachable;
    for (0..@intCast(rl_font.glyphCount)) |i| {
        try f.addGlyph(store.a, rl_font.glyphs[i].value, .{
            .width = rl_font.recs[i].width,
            .offsetX = @as(f32, @floatFromInt(rl_font.glyphs[i].offsetX)),
            .advanceX = @as(f32, @floatFromInt(rl_font.glyphs[i].advanceX)),
        });
    }
}
