const std = @import("std");
const rl = @import("raylib");
const window_backend = @import("window_backend");

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

    var kem = try kbs.KeyboardEventsManager.init(gpa);
    defer kem.deinit();

    var win = try window_backend.WindowBackend.create(gpa, try window_backend.ts.Language.get("zig"), window_backend.zig_highlight_scm);
    defer win.deinit();

    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

    var trigger_map = try exp.createTriggerMap(gpa);
    defer trigger_map.deinit();

    var prefix_map = try exp.createPrefixMap(gpa);
    defer prefix_map.deinit();

    const TriggerCandidateComposer = kbs.GenericTriggerCandidateComposer(exp.TriggerMap, exp.PrefixMap);
    var composer = try TriggerCandidateComposer.init(gpa, &trigger_map, &prefix_map);
    defer composer.deinit();

    var picker = try kbs.TriggerPicker.init(gpa, &kem.old_list, &kem.new_list, &kem.time_list);
    defer picker.deinit();

    ///////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        try kem.updateNew();

        {
            const insert_mode_active = true;
            var trigger: []const u8 = "";

            const candidate = try composer.getTriggerCandidate(kem.old_list.items, kem.new_list.items);
            if (!insert_mode_active) {
                if (candidate) |c| trigger = c;
            }
            if (insert_mode_active) {
                const may_final_trigger = try picker.getFinalTrigger(candidate);
                if (may_final_trigger) |t| trigger = t;
            }

            if (!eql(u8, trigger, "")) {
                defer picker.a.free(trigger);
                std.debug.print("trigger: {s}\n", .{trigger});

                /////////////////////////////

                for (exp.letters_and_numbers) |chars|
                    if (eql(u8, chars, trigger)) try win.insertChars(chars);

                if (eql(u8, trigger, "space")) try win.insertChars(" ");
                if (eql(u8, trigger, "tab")) try win.insertChars("    ");
                if (eql(u8, trigger, "enter")) try win.insertChars("\n");

                /////////////////////////////

                if (eql(u8, trigger, "up")) win.cursor.up(1);
                if (eql(u8, trigger, "down")) win.cursor.down(1, win.buffer.num_of_lines());
                if (eql(u8, trigger, "left")) win.cursor.left(1);
                if (eql(u8, trigger, "right")) win.cursor.right(1, try win.buffer.num_of_chars_in_line(win.cursor.line));
            }
        }

        {
            rl.clearBackground(rl.Color.blank);

            { // display cursor position
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buf, "({d}, {d})", .{ win.cursor.line, win.cursor.col }) catch "error";
                rl.drawTextEx(font, text, .{ .x = 700, .y = 400 }, 30, 0, rl.Color.ray_white);
            }

            { // display text_buffer
                const start_x = 100;
                const start_y = 100;

                const font_size = 40;
                const spacing = 0;

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
                    rl.drawTextEx(font, text, .{ .x = start_x + x, .y = start_y + y }, font_size, spacing, cell.color);

                    const measure = rl.measureTextEx(font, text, font_size, spacing);
                    x += measure.x;
                }
            }
        }

        try kem.updateOld();
    }
}
