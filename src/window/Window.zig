const Window = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const DisplayCachePool = @import("DisplayCachePool.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
dcp: *DisplayCachePool,

x: f32,
y: f32,
bounds: Bounds,
bounded: bool,

pub fn create(a: Allocator, opts: *SpawnOptions) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .dcp = opts.dcp,

        .x = opts.x,
        .y = opts.y,
        .bounds = if (opts.bounds) |b| b else Bounds{},
        .bounded = if (opts.bounds) |_| true else false,
    };
    return self;
}

pub fn desroy(self: *@This()) void {
    try self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const SpawnOptions = struct {
    x: f32 = 0,
    y: f32 = 0,
    bounds: ?Bounds = null,

    render_callbacks: ?RenderCallbacks,
    dcp: *DisplayCachePool,
};

pub const RenderCallbacks = struct {
    drawCodePoint: *const fn (ctx: *anyopaque, code_point: u21, font_face: []const u8, font_size: f32, color: u32, x: f32, y: f32) void,
    drawRectangle: *const fn (x: f32, y: f32, width: f32, height: f32, color: u32) void,

    camera: *anyopaque,
    getMousePositionOnScreen: *const fn (camera: *anyopaque) struct { f32, f32 },

    smooth_cam: *anyopaque,
    setSmoothCamTarget: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    changeTargetXBy: *const fn (ctx: *anyopaque, by: f32) void,
    changeTargetYBy: *const fn (ctx: *anyopaque, by: f32) void,

    screen_view: *anyopaque,
    getScreenView: *const fn (ctx: *anyopaque) ScreenView,
};

pub const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};

pub const Bounds = struct {
    width: f32 = 400,
    height: f32 = 400,
    padding: Padding = .{},
    offset: Offset = .{},

    const Padding = struct {
        top: f32 = 0,
        right: f32 = 0,
        bottom: f32 = 0,
        left: f32 = 0,
    };

    const Offset = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};
