const std = @import("std");
const rl = @import("raylib");

const kbs = @import("keyboard/state.zig");

const c_allocator = std.heap.c_allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 800;
const screen_height = 450;

pub fn main() anyerror!void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Communism Studio");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    // rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Game State

    var old_event_array = [_]bool{false} ** 400;
    var new_event_array = [_]bool{false} ** 400;
    var old_event_list = kbs.EventList.init(c_allocator);
    var new_event_list = kbs.EventList.init(c_allocator);
    var event_time_list = kbs.EventTimeList.init(c_allocator);

    var test_trigger_map = try kbs.createTriggerMapForTesting(c_allocator);
    var test_prefix_map = try kbs.createPrefixMapForTesting(c_allocator);
    const TestInvoker = kbs.GenericInvoker(kbs.TestTriggerMap, kbs.TestPrefixMap);
    const test_invoker = try TestInvoker.init(c_allocator, &test_trigger_map, &test_prefix_map);

    ///////////////////////////// Main Loop

    {
        while (!rl.windowShouldClose()) {
            rl.beginDrawing();
            defer rl.endDrawing();

            try kbs.updateEventList(&new_event_array, &new_event_list, &event_time_list);

            {
                const maybe_trigger = try test_invoker.getTrigger(old_event_list.items, new_event_list.items);
                if (maybe_trigger) |trigger| {
                    if (test_trigger_map.get(trigger)) |value| {
                        std.debug.print("{s}\n", .{value});
                    }
                }
            }

            {
                rl.clearBackground(rl.Color.blank);

                rl.drawText("Congrats! You created your first window!", 190, 200, 20, rl.Color.sky_blue);
            }

            try kbs.updateEventList(&old_event_array, &old_event_list, null);
        }
    }
}
