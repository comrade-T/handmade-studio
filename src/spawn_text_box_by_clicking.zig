const std = @import("std");
const rl = @import("raylib");

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

    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

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

    ///////////////////////////// Models

    // FileNavigator

    var navigator = try FileNavigator.new(gpa);
    defer navigator.deinit();

    // Buffer & ContentVendor

    var buf = try Buffer.create(gpa, .string, "");
    try buf.initiateTreeSitter(.zig);
    defer buf.destroy();

    const vendor = try ContentVendor.init(gpa, buf);
    defer vendor.deinit();

    const window = try Window.spawn(gpa, vendor, 400, 100);
    defer window.destroy();

    ///////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {
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
                                // TODO:
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

        // View
        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            {
                for (navigator.short_paths, 0..) |path, i| {
                    const text = try std.fmt.allocPrintZ(gpa, "{s}", .{path});
                    defer gpa.free(text);
                    const idx: i32 = @intCast(i);
                    const color = if (i == navigator.index) rl.Color.sky_blue else rl.Color.ray_white;
                    rl.drawText(text, 100, 100 + idx * 40, 30, color);
                }
            }
            {
                const iter = try vendor.requestLines(0, vendor.buffer.roperoot.weights().bols - 1);
                defer iter.deinit();

                const spacing = 0;
                const font_size = 40;
                var x: f32 = window.x;
                var y: f32 = window.y;

                var char_buf: [10]u8 = undefined;
                while (iter.nextChar(&char_buf)) |char| {
                    const txt, const hex = char;
                    if (txt[0] == '\n') {
                        y += font_size;
                        x = window.x;
                        continue;
                    }
                    rl.drawTextEx(font, txt, .{ .x = x, .y = y }, font_size, spacing, rl.Color.fromInt(hex));
                    const measure = rl.measureTextEx(font, txt, font_size, spacing);
                    x += measure.x;
                }
            }
        }
    }
}
