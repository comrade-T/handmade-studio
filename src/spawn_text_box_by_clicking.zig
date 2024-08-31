const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");
const FileNavigator = @import("components/FileNavigator.zig");

const _neo_buffer = @import("neo_buffer");
const _vw = @import("virtuous_window");
const Window = _vw.Window;
const Buffer = _neo_buffer.Buffer;

const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

// TODO: drag the camera around

pub fn main() anyerror!void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Ugly");
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

    ///////////////////////////// Controller

    var kem = try kbs.KeyboardEventsManager.init(gpa);
    defer kem.deinit();

    var trigger_map = try exp.createTriggerMap(gpa);
    defer trigger_map.deinit();

    var prefix_map = try exp.createPrefixMap(gpa);
    defer prefix_map.deinit();

    const TriggerCandidateComposer = kbs.GenericTriggerCandidateComposer(exp.TriggerMap, exp.PrefixMap);
    var composer = try TriggerCandidateComposer.init(gpa, &trigger_map, &prefix_map);
    defer composer.deinit();

    const TriggerPicker = kbs.GenericTriggerPicker(exp.TriggerMap);
    var picker = try TriggerPicker.init(gpa, &trigger_map);
    defer picker.deinit();

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

        try kem.startHandlingInputs();
        {
            const input_steps = try kem.inputSteps();
            defer input_steps.deinit();

            for (input_steps.items) |step| {
                const insert_mode_active = true;
                var trigger: []const u8 = "";

                const candidate = try composer.getTriggerCandidate(step.old, step.new);
                if (!insert_mode_active) {
                    if (candidate) |c| trigger = c;
                }
                if (insert_mode_active) {
                    const may_final_trigger = try picker.getFinalTrigger(step.old, step.new, step.time, candidate);
                    if (may_final_trigger) |t| trigger = t;
                }

                if (!eql(u8, trigger, "")) {
                    std.debug.print("trigger: {s}\n", .{trigger});

                    { // navigator stuffs
                        if (eql(u8, trigger, "lctrl j")) navigator.moveDown();
                        if (eql(u8, trigger, "lctrl k")) navigator.moveUp();
                        if (eql(u8, trigger, "lctrl l")) {
                            if (try navigator.forward()) |path| {
                                defer path.deinit();

                                buf.destroy();
                                window.destroy();

                                buf = try Buffer.create(gpa, .file, path.items);
                                try buf.initiateTreeSitter(zig_langsuite);
                                window = try Window.spawn(gpa, buf, font_size, 400, 100, null);
                                // window = try Window.spawn(gpa, buf, font_size, 400, 100, .{
                                //     .width = 500,
                                //     .height = 500,
                                // });
                            }
                        }
                        if (eql(u8, trigger, "lctrl h")) try navigator.backwards();
                    }

                    { // Buffer actions
                        if (eql(u8, trigger, "z")) {
                            var delta = rl.getMouseDelta();
                            delta = delta.scale(-1 / camera.zoom);
                            window.moveBy(delta.x, delta.y);
                        }
                        // if (trigger_map.get(trigger)) |a| {
                        //     switch (a) {
                        //         .insert => |chars| {
                        //             _ = chars;
                        //             // window.insertChars(chars);
                        //         },
                        //         .custom => {},
                        //     }
                        // }
                    }
                }
            }
        }
        try kem.finishHandlingInputs();

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
            defer ztracy.PlotU("chars_rendered", chars_rendered);

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
