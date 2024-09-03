const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const FileNavigator = @import("components/FileNavigator.zig");

const _neo_buffer = @import("neo_buffer");
const _vw = @import("virtuous_window");
const Window = _vw.Window;
const Buffer = _neo_buffer.Buffer;

const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const _input_processor = @import("input_processor");
const Key = _input_processor.Key;
const hash = _input_processor.hash;

//////////////////////////////////////////////////////////////////////////////////////////////

// TODO: emap(trigger, cmd_id) --> switch statement on the cmd_id.
// --> that would require setting up APIs in a way that is re-mappable.

// TODO: RIGHT NOW:
// - Window controls (window position, window bounds)
// - Vim editting

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Application");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ///////////////////////////// Font

    const font_size = 150;
    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

    const font_data = try generateFontData(gpa, font);
    defer gpa.free(font_data.recs);
    defer gpa.free(font_data.glyphs);

    var font_data_index_map = try _vw.createFontDataIndexMap(gpa, font_data);
    defer font_data_index_map.deinit();

    ///////////////////////////// Camera

    var camera = rl.Camera2D{
        .offset = .{ .x = 0, .y = 0 },
        .target = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = 1,
    };

    var view_start = rl.Vector2{ .x = 0, .y = 0 };
    var view_end = rl.Vector2{ .x = screen_width, .y = screen_height };
    var view_width: f32 = screen_width;
    var view_height: f32 = screen_height;

    ///////////////////////////// New Input

    const _keyboard_setup_zone = ztracy.ZoneNC(@src(), "input setup zone", 0x00AA00);

    var vault = try _input_processor.MappingVault.init(gpa);
    defer vault.deinit();

    // TODO:

    { // editor mode tests
        try vault.emap(&[_]Key{.j});
        try vault.emap(&[_]Key{.k});
        try vault.emap(&[_]Key{.l});

        try vault.emap(&[_]Key{.a});
        try vault.emap(&[_]Key{ .l, .a });
        try vault.emap(&[_]Key{ .l, .z });
        try vault.emap(&[_]Key{ .l, .z, .c });

        try vault.emap(&[_]Key{.b});

        try vault.emap(&[_]Key{ .left_control, .h });
        try vault.emap(&[_]Key{ .left_control, .j });
        try vault.emap(&[_]Key{ .left_control, .k });
        try vault.emap(&[_]Key{ .left_control, .l });
    }

    var frame = try _input_processor.InputFrame.init(gpa);
    defer frame.deinit();

    var last_trigger_timestamp: i64 = 0;

    var reached_trigger_delay = false;
    var reached_repeat_rate = false;

    const trigger_delay = 150;
    const repeat_rate = 1000 / 62;

    _keyboard_setup_zone.End();

    ///////////////////////////// Models

    // FileNavigator

    var navigator = try FileNavigator.new(gpa);
    defer navigator.deinit();

    // Buffer & Tree Sitter & Window

    var zig_langsuite = try _neo_buffer.sitter.LangSuite.create(.zig);
    defer zig_langsuite.destroy();
    try zig_langsuite.initializeQuery();
    try zig_langsuite.initializeFilter(gpa);
    try zig_langsuite.initializeHighlightMap(gpa);

    var buf = try Buffer.create(gpa, .string, "");
    try buf.initiateTreeSitter(zig_langsuite);
    defer buf.destroy();

    var window = try Window.spawn(gpa, buf, font_size, 400, 100, null);
    defer window.destroy();

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Camera

        // drag while holding Right Mouse Button
        if (rl.isMouseButtonDown(.mouse_button_right)) {
            var delta = rl.getMouseDelta();
            delta = delta.scale(-1 / camera.zoom);
            camera.target = delta.add(camera.target);
        }

        { // zoom with scroll wheel
            const wheel = rl.getMouseWheelMove();
            if (wheel != 0) {
                const mouse_pos = rl.getMousePosition();
                const mouse_world_pos = rl.getScreenToWorld2D(mouse_pos, camera);
                camera.offset = mouse_pos;
                camera.target = mouse_world_pos;

                var scale_factor = 1 + (0.25 * @abs(wheel));
                if (wheel < 0) scale_factor = 1 / scale_factor;
                camera.zoom = rl.math.clamp(camera.zoom * scale_factor, 0.125, 64);
            }
        }

        { // update screen bounding box variables
            view_start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
            view_end = rl.getScreenToWorld2D(.{ .x = screen_width, .y = screen_height }, camera);
            view_width = view_end.x - view_start.x;
            view_height = view_end.y - view_start.y;
        }

        ///////////////////////////// Keyboard

        blk: {
            const zone = ztracy.ZoneNC(@src(), "Keyboard loop zone", 0x00AAFF);
            defer zone.End();

            var i: usize = frame.downs.items.len;
            while (i > 0) {
                i -= 1;
                const code: c_int = @intCast(@intFromEnum(frame.downs.items[i].key));
                const key: rl.KeyboardKey = @enumFromInt(code);
                if (rl.isKeyUp(key)) {
                    try frame.keyUp(frame.downs.items[i].key);

                    // std.debug.print("up it!\n", .{});
                    reached_trigger_delay = false;
                    reached_repeat_rate = false;
                }
            }

            for (_input_processor.Key.values) |value| {
                const code: c_int = @intCast(value);
                if (rl.isKeyDown(@enumFromInt(code))) {
                    const enum_value: _input_processor.Key = @enumFromInt(value);
                    try frame.keyDown(enum_value, .now);
                }
            }

            if (_input_processor.produceTrigger(
                .editor,
                &frame,
                _input_processor.MappingVault.down_checker,
                _input_processor.MappingVault.up_checker,
                vault,
            )) |trigger| {
                // std.debug.print("trigger: 0x{x}\n", .{trigger});
                const current_time = std.time.milliTimestamp();

                trigger: {
                    if (reached_repeat_rate) {
                        if (current_time - last_trigger_timestamp < repeat_rate) break :blk;
                        last_trigger_timestamp = current_time;
                        break :trigger;
                    }

                    if (reached_trigger_delay) {
                        if (current_time - last_trigger_timestamp < trigger_delay) break :blk;
                        reached_repeat_rate = true;
                        last_trigger_timestamp = current_time;
                        break :trigger;
                    }

                    if (current_time - last_trigger_timestamp < trigger_delay) break :blk;
                    reached_trigger_delay = true;
                    last_trigger_timestamp = current_time;
                }

                switch (trigger) {
                    hash(&[_]Key{.a}) => {
                        std.debug.print("Alice in Wonderland\n", .{});
                    },
                    hash(&[_]Key{.b}) => {
                        std.debug.print("Big Bang raise the roof\n", .{});
                    },

                    hash(&[_]Key{ .left_control, .h }) => try navigator.backwards(),
                    hash(&[_]Key{ .left_control, .k }) => navigator.moveUp(),
                    hash(&[_]Key{ .left_control, .j }) => navigator.moveDown(),
                    hash(&[_]Key{ .left_control, .l }) => {
                        if (try navigator.forward()) |path| {
                            defer path.deinit();

                            buf.destroy();
                            window.destroy();

                            buf = try Buffer.create(gpa, .file, path.items);
                            try buf.initiateTreeSitter(zig_langsuite);
                            window = try Window.spawn(gpa, buf, font_size, 400, 100, null);
                        }
                    },

                    else => {},
                }
            }
        }

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.drawFPS(10, 10);

            rl.clearBackground(rl.Color.blank);
            { // navigator
                for (navigator.short_paths, 0..) |path, i| {
                    const text = try std.fmt.allocPrintZ(gpa, "{s}", .{path});
                    defer gpa.free(text);
                    const idx: i32 = @intCast(i);
                    const color = if (i == navigator.index) rl.Color.sky_blue else rl.Color.ray_white;
                    rl.drawText(text, 100, 100 + idx * 40, 30, color);
                }
            }

            var chars_rendered: u64 = 0;
            // defer ztracy.PlotU("chars_rendered", chars_rendered);

            { // window content
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                var iter = window.codePointIter(font_data, font_data_index_map, .{
                    .start_x = view_start.x,
                    .start_y = view_start.y,
                    .end_x = view_end.x,
                    .end_y = view_end.y,
                });

                while (iter.next()) |result| {
                    switch (result) {
                        .code_point => |char| {
                            rl.drawTextCodepoint(font, char.value, .{ .x = char.x, .y = char.y }, font_size, rl.Color.fromInt(char.color));
                            chars_rendered += 1;
                        },
                        else => continue,
                    }
                }
            }

            try drawTextAtBottomRight(
                "chars rendered: {d}",
                .{chars_rendered},
                30,
                .{ .x = 40, .y = 40 },
            );

            // try drawTextAtBottomRight(
            //     "[{d}, {d}]",
            //     .{ window.cursor.line, window.cursor.col },
            //     30,
            //     .{ .x = 40, .y = 120 },
            // );
        }
    }
}

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}

fn generateFontData(a: Allocator, font: rl.Font) !_vw.FontData {
    var recs = try a.alloc(_vw.Rectangle, @intCast(font.glyphCount));
    var glyphs = try a.alloc(_vw.GlyphData, @intCast(font.glyphCount));

    for (0..@intCast(font.glyphCount)) |i| {
        recs[i] = _vw.Rectangle{
            .x = font.recs[i].x,
            .y = font.recs[i].y,
            .width = font.recs[i].width,
            .height = font.recs[i].height,
        };

        glyphs[i] = _vw.GlyphData{
            .advanceX = font.glyphs[i].advanceX,
            .offsetX = @intCast(font.glyphs[i].offsetX),
            .value = font.glyphs[i].value,
        };
    }

    return .{
        .base_size = font.baseSize,
        .glyph_padding = font.glyphPadding,
        .recs = recs,
        .glyphs = glyphs,
    };
}
