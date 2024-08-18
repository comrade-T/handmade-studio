const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");
const FileNavigator = @import("components/FileNavigator.zig");

const _neo_buffer = @import("neo_buffer");
const _content_vendor = @import("content_vendor");
const _neo_window = @import("neo_window");
const Buffer = _neo_buffer.Buffer;
const ContentVendor = _content_vendor.ContentVendor;
const Window = _neo_window.Window;

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

    ///////////////////////////// Controller

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    var kem = try kbs.KeyboardEventsManager.init(gpa);
    defer kem.deinit();

    const font_size = 150;
    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

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

    ///////////////////////////// Models

    // FileNavigator

    var navigator = try FileNavigator.new(gpa);
    defer navigator.deinit();

    // Buffer & ContentVendor

    var buf = try Buffer.create(gpa, .string, "");
    try buf.initiateTreeSitter(.zig);
    defer buf.destroy();

    var vendor = try ContentVendor.init(gpa, buf);
    defer vendor.deinit();

    var window = try Window.spawn(gpa, vendor, 400, 100);
    defer window.destroy();

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Camera

        if (rl.isMouseButtonDown(.mouse_button_right)) {
            var delta = rl.getMouseDelta();
            delta = delta.scale(-1 / camera.zoom);
            camera.target = delta.add(camera.target);
        }

        {
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
                    defer picker.a.free(trigger);

                    { // navigator stuffs
                        if (eql(u8, trigger, "lctrl j")) navigator.moveDown();
                        if (eql(u8, trigger, "lctrl k")) navigator.moveUp();
                        if (eql(u8, trigger, "lctrl l")) {
                            if (try navigator.forward()) |path| {
                                defer path.deinit();

                                buf.destroy();
                                vendor.deinit();
                                window.destroy();

                                buf = try Buffer.create(gpa, .file, path.items);
                                try buf.initiateTreeSitter(.zig);
                                vendor = try ContentVendor.init(gpa, buf);
                                window = try Window.spawn(gpa, vendor, 400, 100);
                            }
                        }
                        if (eql(u8, trigger, "lctrl h")) try navigator.backwards();
                    }

                    { // Buffer actions
                        if (trigger_map.get(trigger)) |a| {
                            switch (a) {
                                .insert => |chars| window.insertChars(chars),
                                .custom => try window.doCustomStuffs(trigger),
                            }
                        }
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
            { // window content
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                // const iter = try vendor.requestLines(0, vendor.buffer.roperoot.weights().bols - 1);
                const iter = try vendor.requestLines(0, 999);
                defer iter.deinit();

                const spacing = 0;
                var x: f32 = window.x;
                var y: f32 = window.y;

                var char_buf: [10]u8 = undefined;
                while (true) {
                    const result = iter.nextChar(&char_buf);
                    const char = if (result) |c| c else break;

                    const txt, const hex = char;
                    if (txt[0] == '\n') {
                        y += font_size;
                        x = window.x;
                        continue;
                    }

                    {
                        const zone = ztracy.ZoneNC(@src(), "rl.drawText()", 0x0F00F0);
                        defer zone.End();

                        rl.drawTextEx(font, txt, .{ .x = x, .y = y }, font_size, spacing, rl.Color.fromInt(hex));
                        const measure = rl.measureTextEx(font, txt, font_size, spacing);
                        x += measure.x;
                    }
                }
            }
            { // window cursor
                var txt_buf: [20]u8 = undefined;
                const txt = try std.fmt.bufPrintZ(&txt_buf, "[{d}, {d}]", .{ window.cursor.line, window.cursor.col });
                rl.drawTextEx(font, txt, .{ .x = screen_width - 200, .y = screen_height - 100 }, 40, 0, rl.Color.ray_white);
            }
        }
    }
}
