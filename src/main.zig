const std = @import("std");
const rl = @import("raylib");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");
const buffer_module = @import("buffer");
const Buffer = buffer_module.Buffer;
const Cursor = @import("buffer/cursor.zig").Cursor;

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

    var old_event_array = [_]bool{false} ** 400;
    var new_event_array = [_]bool{false} ** 400;

    var old_event_list = kbs.EventList.init(gpa);
    defer old_event_list.deinit();

    var new_event_list = kbs.EventList.init(gpa);
    defer new_event_list.deinit();

    var event_time_list = kbs.EventTimeList.init(gpa);
    defer event_time_list.deinit();

    var trigger_map = try exp.createTriggerMap(gpa);
    defer trigger_map.deinit();

    var prefix_map = try exp.createPrefixMap(gpa);
    defer prefix_map.deinit();

    const TriggerCandidateComposer = kbs.GenericTriggerCandidateComposer(exp.TriggerMap, exp.PrefixMap);
    var candidate_maker = try TriggerCandidateComposer.init(gpa, &trigger_map, &prefix_map);
    defer candidate_maker.deinit();

    var insert_mode_trigger_picker = try kbs.InsertModeTriggerPicker.init(gpa, &old_event_list, &new_event_list, &event_time_list);
    defer insert_mode_trigger_picker.deinit();

    ///////////////////////////// Text Buffer

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var text_buffer = try Buffer.create(a, gpa);
    defer text_buffer.deinit();

    var cursor = Cursor{};

    text_buffer.root = try text_buffer.load_from_string("");
    var cached_contents = try text_buffer.toArrayList(gpa);
    defer cached_contents.deinit();

    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

    ///////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        try kbs.updateEventList(&new_event_array, &new_event_list, &event_time_list);

        {
            const insert_mode_active = true;

            const candidate = try candidate_maker.getTriggerCandidate(old_event_list.items, new_event_list.items);

            var trigger: []const u8 = "";
            if (!insert_mode_active) {
                if (candidate) |t| switch (t) {
                    .down => trigger = t.down,
                    .up => trigger = t.up,
                };
            }
            if (insert_mode_active) {
                const may_trigger = try insert_mode_trigger_picker.getFinalTrigger(candidate);
                if (may_trigger) |t| {
                    trigger = t;
                }
            }

            if (!eql(u8, trigger, "")) {
                defer insert_mode_trigger_picker.a.free(trigger);
                std.debug.print("trigger: {s}\n", .{trigger});

                if (trigger_map.get(trigger)) |_| {
                    if (trigger.len == 1)
                        for (exp.letters_and_numbers) |chars|
                            if (eql(u8, chars, trigger))
                                try insert_chars(gpa, trigger, text_buffer, &cursor, &cached_contents);

                    if (eql(u8, trigger, "space")) try insert_chars(gpa, " ", text_buffer, &cursor, &cached_contents);
                    if (eql(u8, trigger, "tab")) try insert_chars(gpa, "    ", text_buffer, &cursor, &cached_contents);
                    if (eql(u8, trigger, "enter")) try insert_chars(gpa, "\n", text_buffer, &cursor, &cached_contents);

                    if (eql(u8, trigger, "up")) cursor.up(1);
                    if (eql(u8, trigger, "left")) cursor.left(1);
                    if (eql(u8, trigger, "down")) {
                        cursor.down(1, text_buffer.num_of_lines());
                        return;
                    }
                    if (eql(u8, trigger, "right")) {
                        const line_width = try text_buffer.num_of_chars_in_line(cursor.line);
                        cursor.right(1, line_width);
                    }

                    if (eql(u8, trigger, "backspace")) {
                        text_buffer.root = try text_buffer.delete_chars(text_buffer.a, cursor.line, cursor.col -| 1, 1);
                        cursor.left(1);

                        cached_contents.deinit();
                        cached_contents = try text_buffer.toArrayList(gpa);
                    }
                }
            }
        }

        {
            rl.clearBackground(rl.Color.blank);

            { // display cursor position
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrintZ(&buf, "({d}, {d})", .{ cursor.line, cursor.col }) catch "error";
                rl.drawTextEx(font, text, .{ .x = 700, .y = 400 }, 30, 0, rl.Color.ray_white);
            }

            { // display text_buffer
                if (cached_contents.items.len > 0) {
                    if (cached_contents.items[cached_contents.items.len - 1] != 0) {
                        try cached_contents.ensureTotalCapacityPrecise(cached_contents.items.len + 1);
                        cached_contents.appendAssumeCapacity(0);
                    }

                    const text = cached_contents.items[0 .. cached_contents.items.len - 1 :0];

                    rl.drawTextEx(font, text, .{ .x = 100, .y = 100 }, 40, 0, rl.Color.ray_white);
                }
            }
        }

        try kbs.updateEventList(&old_event_array, &old_event_list, null);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const eql = std.mem.eql;

fn insert_chars(
    a: std.mem.Allocator,
    chars: []const u8,
    buf: *Buffer,
    cursor: *Cursor,
    cached_contents: *std.ArrayList(u8),
) !void {
    _, _, buf.root = try buf.insert_chars(buf.a, cursor.line, cursor.col, chars);

    cached_contents.deinit();
    cached_contents.* = try buf.toArrayList(a);

    if (eql(u8, chars, "\n")) {
        const line = cursor.line + 1;
        const col = 0;
        cursor.set(line, col);
        return;
    }
    cursor.right(buffer_module.num_of_chars(chars), try buf.num_of_chars_in_line(cursor.line));
}
