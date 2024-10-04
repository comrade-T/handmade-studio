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

start_line: usize,
end_line: usize,

x: f32,
y: f32,
padding: Padding,
bounds: Bounds,
bounded: bool,

rcb: *RenderCallbacks,

pub fn create(a: Allocator, opts: *SpawnOptions) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .dcp = opts.dcp,

        .start_line = opts.start_line,
        .end_line = opts.end_line,

        .x = opts.x,
        .y = opts.y,
        .padding = if (opts.padding) |p| p else Padding{},
        .bounds = if (opts.bounds) |b| b else Bounds{},
        .bounded = if (opts.bounds) |_| true else false,

        .rcb = opts.render_callbacks,
    };
    return self;
}

pub fn desroy(self: *@This()) void {
    try self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), view: ScreenView) void {
    const lines = self.dcp.requestLines(self.start_line, self.end_line);
    self.renderCharacters(lines, view);
}

fn renderCharacters(self: *@This(), lines: []DisplayCachePool.Line, view: ScreenView) void {
    if (!self.bounded) {
        self.renderCharactersForUnboundWindow(lines, view);
        return;
    }
    unreachable;
}

fn renderCharactersForUnboundWindow(self: *@This(), lines: []DisplayCachePool.Line, view: ScreenView) void {
    var current_x = self.x;
    var current_y = self.y;

    for (lines) |line| {
        const later_y = current_y + line.height;

        defer current_x = self.x;
        defer current_y = later_y;

        if (current_y > view.end.y) return;
        if (later_y < view.start.y) continue;

        for (line.displays, 0..) |d, j| {
            if (current_x > view.end.x) break;

            const later_x = current_x + d.width;
            defer current_x += later_x;

            if (later_x < view.start.x) continue;

            switch (d.variant) {
                .char => |char| {
                    self.rcb.drawCodePoint(
                        self.rcb.font_manager,
                        line.contents[j],
                        char.font_face,
                        char.font_size,
                        char.color,
                        current_x,
                        current_y,
                    );
                },
                else => {},
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const SpawnOptions = struct {
    x: f32 = 0,
    y: f32 = 0,
    bounds: ?Bounds = null,
    padding: ?Padding = null,

    start_line: usize,
    end_line: usize,

    render_callbacks: *RenderCallbacks,
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
    offset: Offset = .{},

    const Offset = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};

const Padding = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
};
