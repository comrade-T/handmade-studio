const std = @import("std");
const r = @cImport({
    @cInclude("raylib.h");
});

const gp_state = @import("gamepad/state.zig");
const gp_view = @import("gamepad/view.zig");

const kbs = @import("keyboard/state.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_w = 800;
const screen_h = 450;

const device_idx = 1;

pub const GameState = struct {
    allocator: std.mem.Allocator,
    time: f32 = 0,
    radius: f32 = 0,

    // gamepad experiment
    previous_gamepad_state: gp_state.GamepadState = undefined,
    gamepad_buffer: [1024]u8 = undefined,
    gamepad_string: [*c]const u8 = "",

    // keyboard experiment
    key_map: std.AutoHashMap(c_int, kbs.KeyDownEvent),
};

//////////////////////////////////////////////////////////////////////////////////////////////

export fn gameInit(allocator_ptr: *anyopaque) *anyopaque {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(allocator_ptr));
    const gs = allocator.create(GameState) catch @panic("Out of memory.");

    gs.* = GameState{
        .allocator = allocator.*,
        .radius = readRadiusConfig(allocator.*),
        .key_map = std.AutoHashMap(c_int, kbs.KeyDownEvent).init(allocator.*),
    };

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

    kbs.updateKeyMap(&gs.key_map) catch @panic("Error in kbs.updateKeyMap()");

    var iterator = gs.key_map.iterator();
    while (iterator.next()) |entry| {
        std.debug.print("{d}:{any}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    // TODO: but, instead of using bool as value, we have a custom structure that also store timestamp and string char
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
