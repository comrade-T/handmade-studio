const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const LangSuite = @import("LangSuite");

//////////////////////////////////////////////////////////////////////////////////////////////

const initial_screen_width = 1920;
const default_screen_height = 1080;

pub fn main() !void {

    ///////////////////////////// Init

    rl.setConfigFlags(.{ .window_transparent = false, .vsync_hint = true });
    rl.initWindow(initial_screen_width, default_screen_height, "Handmade Studio");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// State

    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    // LangSuite
    var ls = try LangSuite.create(gpa, .zig);
    try ls.addDefaultHighlightQuery();
    defer ls.destroy();

    try badMemory(gpa, ls);

    ////////////////////////////////////////////////////////////////////////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.blank);
        rl.drawFPS(10, 10);

        if (rl.isMouseButtonPressed(.mouse_button_left)) {
            try badMemory(gpa, ls);
        }

        rl.drawText("fonkafonk", 100, 100, 30, rl.Color.ray_white);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn badMemory(gpa: std.mem.Allocator, ls: *LangSuite) !void {
    const zone = ztracy.ZoneNC(@src(), "badMemory()", 0x00FF00);
    defer zone.End();

    // Test Syntax Tree
    var parser = try ls.createParser();
    defer parser.destroy();
    const test_source = @embedFile("window/old_window.zig");
    const tree = try parser.parseString(null, test_source);

    // StyleParser
    var style_parser = try LangSuite.StyleParser.create(gpa);
    defer style_parser.destroy();
    try style_parser.addQuery(LangSuite.DEFAULT_QUERY_ID);

    var noc_map = try LangSuite.StyleParser.produceNocMapForTesting(gpa, test_source);
    defer noc_map.deinit();

    try style_parser.parse(ls, tree, test_source, noc_map, null);
}
