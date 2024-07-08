const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const gp_state = @import("gamepad/state.zig");
const gp_view = @import("gamepad/view.zig");

const kbs = @import("keyboard/state.zig");
const Buffer = @import("buffer").Buffer;
const eM = @import("keyboard/experimental_mappings.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_w = 800;
const screen_h = 450;

const device_idx = 1;

const TestInvoker = kbs.GenericInvoker(kbs.TestTriggerMap, kbs.TestPrefixMap);
const InsertCharInvoker = kbs.GenericInvoker(eM.InsertCharTriggerMap, eM.InsertCharPrefixMap);

pub const GameState = struct {
    allocator: std.mem.Allocator,
    time: f32 = 0,
    radius: f32 = 0,

    // keyboard experiment
    old_event_array: kbs.EventArray = [_]bool{false} ** 400,
    new_event_array: kbs.EventArray = [_]bool{false} ** 400,
    old_event_list: kbs.EventList,
    new_event_list: kbs.EventList,
    event_time_list: kbs.EventTimeList,

    test_trigger_map: kbs.TestTriggerMap,
    test_prefix_map: kbs.TestPrefixMap,
    test_invoker: *TestInvoker,

    // text buffer
    text_buffer: *Buffer,
    insert_char_trigger_map: eM.InsertCharTriggerMap,
    insert_char_prefix_map: eM.InsertCharPrefixMap,
    insert_char_invoker: *InsertCharInvoker,
};

//////////////////////////////////////////////////////////////////////////////////////////////

export fn gameInit(allocator_ptr: *anyopaque) *anyopaque {
    const a: *std.mem.Allocator = @ptrCast(@alignCast(allocator_ptr));
    const gs = a.create(GameState) catch @panic("Out of memory.");

    gs.* = GameState{
        .allocator = a.*,

        .radius = readRadiusConfig(a.*),

        .old_event_list = std.ArrayList(c_int).init(a.*),
        .new_event_list = std.ArrayList(c_int).init(a.*),
        .event_time_list = std.ArrayList(i64).init(a.*),

        .test_trigger_map = kbs.createTriggerMapForTesting(a.*) catch @panic("can't createTriggerMapForTesting"),
        .test_prefix_map = kbs.createPrefixMapForTesting(a.*) catch @panic("can't createPrefixMapForTesting"),
        .test_invoker = TestInvoker.init(a.*, &gs.test_trigger_map, &gs.test_prefix_map) catch @panic("can't init() Invoker"),

        .text_buffer = Buffer.create(a.*, a.*) catch @panic("can't create buffer"),
        .insert_char_trigger_map = eM.createInsertCharCallbackMap(a.*) catch @panic("can't createInsertCharCallbackMap()"),
        .insert_char_prefix_map = eM.InsertCharPrefixMap.init(a.*),
        .insert_char_invoker = InsertCharInvoker.init(a.*, &gs.insert_char_trigger_map, &gs.insert_char_prefix_map) catch @panic("can't init() Invoker"),
    };

    gs.*.text_buffer.root = gs.*.text_buffer.load_from_string("hi there!") catch
        @panic("can't buffer.load_from_string()");

    return gs;
}

export fn gameReload(game_state_ptr: *anyopaque) void {
    var gs: *GameState = @ptrCast(@alignCast(game_state_ptr));
    gs.radius = readRadiusConfig(gs.allocator);
}

export fn gameTick(game_state_ptr: *anyopaque) void {
    var gs: *GameState = @ptrCast(@alignCast(game_state_ptr));
    gs.time += r.GetFrameTime();
}

export fn gameDraw(game_state_ptr: *anyopaque) void {
    const gs: *GameState = @ptrCast(@alignCast(game_state_ptr));
    r.ClearBackground(r.BLANK);

    // var buf: [256]u8 = undefined;
    // const slice = std.fmt.bufPrintZ(&buf, "radius: {d:.02}, time: {d:.02}", .{ gs.radius, gs.time }) catch "error";
    // r.DrawText(slice, 10, 10, 20, r.RAYWHITE);

    // const circle_x: f32 = @mod(gs.time * 240.0, screen_w + gs.radius * 2) - gs.radius;
    // r.DrawCircleV(.{ .x = circle_x, .y = screen_h - gs.radius - 40 }, gs.radius, r.BLUE);

    // const new_gamepad_state = gp_state.getGamepadState(device_idx);
    // gp_view.drawGamepadState(new_gamepad_state, gs);
    // gs.previous_gamepad_state = new_gamepad_state;

    kbs.updateEventList(&gs.new_event_array, &gs.new_event_list, &gs.event_time_list) catch @panic("Error in kbs.updateEventList(new_event_list)");

    {
        const maybe_trigger = gs.test_invoker.getTrigger(gs.old_event_list.items, gs.new_event_list.items) catch @panic("can't invoker.getTrigger");
        if (maybe_trigger) |trigger| {
            if (gs.test_trigger_map.get(trigger)) |value| {
                std.debug.print("{s}\n", .{value});
            }
        }
    }

    {
        const maybe_trigger = gs.insert_char_invoker.getTrigger(gs.old_event_list.items, gs.new_event_list.items) catch @panic("can't invoker.getTrigger");
        if (maybe_trigger) |trigger| {
            if (gs.insert_char_trigger_map.get(trigger)) |*ctx| {
                ctx.callback(gs) catch @panic("can't run callback");
            }
        }
    }

    const text = gs.text_buffer.to_string() catch @panic("can't to_string()");
    r.DrawText(@as([*c]const u8, @ptrCast(text)), 100, 100, 30, r.RAYWHITE);

    kbs.updateEventList(&gs.old_event_array, &gs.old_event_list, null) catch @panic("Error in kbs.updateEventList(old_event_list)");
}

fn readRadiusConfig(allocator: std.mem.Allocator) f32 {
    const default_value: f32 = 40.0;
    const config_filepath = "config/radius.txt";
    const config_data = std.fs.cwd().readFileAlloc(allocator, config_filepath, 1024 * 1024) catch {
        std.debug.print("Failed to read {s}\n", .{config_filepath});
        return default_value;
    };
    defer allocator.free(config_data);
    return std.fmt.parseFloat(f32, config_data[0 .. config_data.len - 1]) catch {
        std.debug.print("Failed to parse {s} in {s}\n", .{ config_data, config_filepath });
        return default_value;
    };
}
