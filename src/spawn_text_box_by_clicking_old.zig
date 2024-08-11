const std = @import("std");
const rl = @import("raylib");

const rope = @import("rope");
const fs = @import("fs.zig");
const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");
const UglyTextBox = @import("ugly_textbox").UglyTextBox;
const FileNavigator = @import("components/FileNavigator.zig");

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

    // const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

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

    // UglyTextBox
    var buf_list = std.ArrayList(*UglyTextBox).init(gpa);
    defer {
        for (buf_list.items) |buf| buf.destroy();
        buf_list.deinit();
    }
    var active_buf: ?*UglyTextBox = null;

    const static_x, const static_y = .{ 400, 100 };
    var static_utb = try UglyTextBox.fromString(gpa, "", static_x, static_y);
    defer static_utb.destroy();

    // FileNavigator
    var navigator = try FileNavigator.new(gpa);
    defer navigator.deinit();

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
                                static_utb.destroy();
                                static_utb = try UglyTextBox.fromFile(gpa, path.items, static_x, static_y);
                            }
                        }
                        if (eql(u8, trigger, "lctrl h")) try navigator.backwards();
                    }

                    try triggerCallback(&trigger_map, trigger, active_buf);
                    // try triggerCallback(&trigger_map, trigger, static_utb);
                }
            }
        }
        try kem.finishHandlingInputs();

        { // Spawn
            if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_left)) {
                const buf = try UglyTextBox.fromString(gpa, "", rl.getMouseX(), rl.getMouseY());
                active_buf = buf;
                try buf_list.append(buf);
            }
        }

        // View
        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            {
                {
                    const content = try std.fmt.allocPrintZ(gpa, "{s}", .{static_utb.document.items});
                    defer gpa.free(content);
                    rl.drawText(content, static_utb.x, static_utb.y, 30, rl.Color.ray_white);
                }
                for (buf_list.items) |utb| {
                    const content = try std.fmt.allocPrintZ(gpa, "{s}", .{utb.document.items});
                    defer gpa.free(content);
                    rl.drawText(content, utb.x, utb.y, 30, rl.Color.ray_white);
                }
            }
            {
                for (navigator.short_paths, 0..) |path, i| {
                    const text = try std.fmt.allocPrintZ(gpa, "{s}", .{path});
                    defer gpa.free(text);
                    const idx: i32 = @intCast(i);
                    const color = if (i == navigator.index) rl.Color.sky_blue else rl.Color.ray_white;
                    rl.drawText(text, 100, 100 + idx * 40, 30, color);
                }
            }
        }
    }
}

fn triggerCallback(trigger_map: *exp.TriggerMap, trigger: []const u8, may_utb: ?*UglyTextBox) !void {
    if (may_utb) |buf| {
        var action: exp.TriggerAction = undefined;
        if (trigger_map.get(trigger)) |a| action = a else return;

        try switch (action) {
            .insert => |chars| buf.insertCharsAndMoveCursor(chars),
            .custom => {},
        };
    }
}
