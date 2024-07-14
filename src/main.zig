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

                // TODO:
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
                for (win.cells.items) |cell| {
                    var buf: [10]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buf, "{s}", .{cell.char}) catch "error";
                    rl.drawTextEx(font, text, .{ .x = 100, .y = 100 }, 40, 0, cell.color);
                }
            }
        }

        try kem.updateOld();
    }
}
