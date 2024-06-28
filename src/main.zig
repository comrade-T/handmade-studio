const std = @import("std");
const pretty = @import("pretty");
const r = @cImport({
    @cInclude("raylib.h");
});

const gp_state = @import("gamepad/state.zig");
const gp_view = @import("gamepad/view.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const GameStatePtr = *anyopaque;

var gameInit: *const fn (*anyopaque) callconv(.C) GameStatePtr = undefined;
var gameReload: *const fn (GameStatePtr) callconv(.C) void = undefined;
var gameTick: *const fn (GameStatePtr) callconv(.C) void = undefined;
var gameDraw: *const fn (GameStatePtr) callconv(.C) void = undefined;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_w = 800;
const screen_h = 450;
const failed_to_load_msg = "Faild to load game.dll";

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    r.InitWindow(screen_w, screen_h, "App");
    defer r.CloseWindow();

    loadGameDll() catch @panic(failed_to_load_msg);

    r.SetTargetFPS(60);
    r.SetExitKey(r.KEY_NULL);
    r.SetConfigFlags(r.FLAG_WINDOW_TRANSPARENT);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const game_state = gameInit(allocator.ptr);

    while (!r.WindowShouldClose()) {
        // if (checker.should_reload()) {
        if (r.IsKeyPressed(r.KEY_F5)) {
            unloadGameDll() catch unreachable;
            loadGameDll() catch @panic(failed_to_load_msg);
            gameReload(game_state);
            // checker.set_should_reload_on_next_loop(false);
        }

        gameTick(game_state);
        r.BeginDrawing();
        gameDraw(game_state);
        r.EndDrawing();

        // const gamepad = 1;
        // const state = gp_state.getGamepadState(gamepad);
        // gp_view.drawGamepadState(state);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

var game_dyn_lib: ?std.DynLib = null;
fn loadGameDll() !void {
    if (game_dyn_lib != null) return error.AlreadyLoaded;
    var dyn_lib = std.DynLib.open("zig-out/lib/libgame.so") catch {
        return error.OpenFail;
    };
    game_dyn_lib = dyn_lib;
    gameInit = dyn_lib.lookup(@TypeOf(gameInit), "gameInit") orelse return error.LookupFail;
    gameReload = dyn_lib.lookup(@TypeOf(gameReload), "gameReload") orelse return error.LookupFail;
    gameTick = dyn_lib.lookup(@TypeOf(gameTick), "gameTick") orelse return error.LookupFail;
    gameDraw = dyn_lib.lookup(@TypeOf(gameDraw), "gameDraw") orelse return error.LookupFail;
    std.debug.print("Loaded game.dll\n", .{});
}

fn unloadGameDll() !void {
    if (game_dyn_lib) |*dyn_lib| {
        dyn_lib.close();
        game_dyn_lib = null;
    } else {
        return error.AlreadyUnloaded;
    }
}
