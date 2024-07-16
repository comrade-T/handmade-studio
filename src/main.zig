const std = @import("std");
const rl = @import("raylib");
const window_backend = @import("window_backend");
const logz = @import("logz");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");

const eql = std.mem.eql;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 800;
const screen_height = 450;

pub fn main() anyerror!void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Communism Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Game State

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    try logz.setup(gpa, .{
        .level = .Debug,
        .pool_size = 100,
        .buffer_size = 4096,
        .large_buffer_count = 8,
        .large_buffer_size = 16384,
        .output = .{ .file = "app.log" },
        .encoding = .logfmt,
    });
    defer logz.deinit();
    logz.info().string("----------------------------------------------", null).log();
    logz.info().string("Program starts!", null).log();

    var kem = try kbs.KeyboardEventsManager.init(gpa);
    defer kem.deinit();

    var win = try window_backend.WindowBackend.createWithTreeSitter(gpa, try window_backend.ts.Language.get("zig"), window_backend.zig_highlight_scm);
    defer win.deinit();

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

    var prev_trigger = try std.fmt.allocPrint(gpa, "", .{});

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
                    // if (candidate) |c| {
                    // std.debug.print("candidate: {s}\n", .{c.trigger});
                    // }
                    const may_final_trigger = try picker.getFinalTrigger(step.old, step.new, step.time, candidate);
                    if (may_final_trigger) |t| trigger = t;
                    if (candidate != null or may_final_trigger != null) {
                        std.debug.print("trigger: {s}\n", .{trigger});
                        // std.debug.print("-------------------------------------\n", .{});
                    }
                }

                if (!eql(u8, trigger, "")) {
                    defer picker.a.free(trigger);

                    const old_prev_trigger = prev_trigger;
                    defer gpa.free(old_prev_trigger);

                    try triggerCallback(&trigger_map, trigger, win, prev_trigger);
                    prev_trigger = try std.fmt.allocPrint(gpa, "{s}", .{trigger});
                }
            }
        }
        try kem.finishHandlingInputs();

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(rl.Color.blank);

        {
            { // display cursor position
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buf, "({d}, {d})", .{ win.cursor.line, win.cursor.col }) catch "error";
                rl.drawTextEx(font, text, .{ .x = 700, .y = 400 }, 30, 0, rl.Color.ray_white);
            }

            { // display text_buffer
                const start_x = 100;
                const start_y = 100;

                const font_size = 40;
                const text_spacing = 0;

                const line_height = 50;

                var x: f32 = 0;
                var y: f32 = 0;

                for (win.cells.items) |cell| {
                    if (cell.char[0] == '\n') {
                        y += line_height;
                        x = 0;
                        continue;
                    }

                    var buf: [10]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buf, "{s}", .{cell.char}) catch "error";
                    rl.drawTextEx(font, text, .{ .x = start_x + x, .y = start_y + y }, font_size, text_spacing, cell.color);

                    const measure = rl.measureTextEx(font, text, font_size, text_spacing);
                    x += measure.x;
                }
            }
        }
    }
}

fn triggerCallback(trigger_map: *exp.TriggerMap, trigger: []const u8, win: *window_backend.WindowBackend, prev_trigger: []const u8) !void {
    var action: exp.TriggerAction = undefined;
    if (trigger_map.get(trigger)) |a| action = a else return;

    logz.debug().string("trigger", trigger).log();

    try switch (action) {
        .insert => |chars| win.insertChars(chars),
        .custom => {
            if (eql(u8, trigger, "backspace")) try win.deleteCharsBackwards(1);

            if (eql(u8, trigger, "up")) win.cursor.up(1);
            if (eql(u8, trigger, "down")) win.cursor.down(1, win.buffer.num_of_lines());
            if (eql(u8, trigger, "left")) win.cursor.left(1);
            if (eql(u8, trigger, "right")) win.cursor.right(1, try win.buffer.num_of_chars_in_line(win.cursor.line));

            if (eql(u8, trigger, "s o")) {
                try win.deleteCharsBackwards(1);
                try win.insertChars("So So");
            }

            if (eql(u8, trigger, "w h")) {
                if (prev_trigger.len > 1 and prev_trigger[0] == 'w') {} else {
                    try win.deleteCharsBackwards(1);
                }
                win.moveCursorBackwardsByWord(1);
            }
            if (eql(u8, trigger, "w l")) {
                if (prev_trigger.len > 1 and prev_trigger[0] == 'w') {} else {
                    try win.deleteCharsBackwards(1);
                }
                win.moveCursorForwardToNextWord(1);
            }
        },
    };
}
