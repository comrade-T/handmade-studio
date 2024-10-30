const Window = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite");
const WindowSource = @import("WindowSource");
const LinkedList = @import("LinkedList").LinkedList;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
ws: *WindowSource,

pos: Position,
padding: Padding,

bounds: Bounds,
bounded: bool,

rcb: ?*RenderCallbacks,

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .ws = ws,

        .pos = opts.pos,
        .padding = if (opts.padding) |p| p else Padding{},

        .bounds = if (opts.bounds) |b| b else Bounds{},
        .bounded = if (opts.bounds) |_| true else false,

        .rcb = opts.render_callbacks,
    };
    return self;
}

test create {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    var ws = try WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
    defer ws.deinit();
    try eqStr("const a = 10;\nvar not_false = true;\n", ws.contents);

    var win = try Window.create(testing_allocator, &ws, .{});
    defer win.destroy();

    // TODO: create width / height list?
}

pub fn destroy(self: *@This()) void {
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), view: ScreenView) void {
    _ = self;
    _ = view;
    // TODO:
}

// fn renderCharacters(self: *@This(), lines: []DisplayCachePool.Line, view: ScreenView) void {
//     if (!self.bounded) {
//         self.renderCharactersForUnboundWindow(lines, view);
//         return;
//     }
//     unreachable;
// }

// fn renderCharactersForUnboundWindow(self: *@This(), lines: []DisplayCachePool.Line, view: ScreenView) void {
//     var current_x = self.x;
//     var current_y = self.y;
//
//     for (lines) |line| {
//         const later_y = current_y + line.height;
//
//         defer current_x = self.x;
//         defer current_y = later_y;
//
//         if (current_y > view.end.y) return;
//         if (later_y < view.start.y) continue;
//
//         for (line.displays, 0..) |d, j| {
//             if (current_x > view.end.x) break;
//
//             const later_x = current_x + d.width;
//             defer current_x += later_x;
//
//             if (later_x < view.start.x) continue;
//
//             switch (d.variant) {
//                 .char => |char| {
//                     self.rcb.drawCodePoint(
//                         self.rcb.font_manager,
//                         line.contents[j],
//                         char.font_face,
//                         char.font_size,
//                         char.color,
//                         current_x,
//                         current_y,
//                     );
//                 },
//                 else => {},
//             }
//         }
//     }
// }

////////////////////////////////////////////////////////////////////////////////////////////// Window Info Types

const SpawnOptions = struct {
    pos: Position = .{},
    bounds: ?Bounds = null,
    padding: ?Padding = null,

    render_callbacks: ?*RenderCallbacks = null,
};

const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Bounds = struct {
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

////////////////////////////////////////////////////////////////////////////////////////////// Callbacks Related

const RenderCallbacks = struct {
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

const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};

////////////////////////////////////////////////////////////////////////////////////////////// Tests

test {
    try std.testing.expectEqual(1, 1);
}
