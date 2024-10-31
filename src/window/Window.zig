const Window = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite");
const WindowSource = @import("WindowSource");
const FontStore = @import("FontStore");

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa_ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_.deinit();
    const gpa = gpa_.allocator();

    var lang_hub = try LangSuite.LangHub.init(gpa);
    defer lang_hub.deinit();

    var font_store = try createMockFontStore(gpa);
    defer font_store.deinit();

    var ws = try WindowSource.init(gpa, .file, "src/window/old_window.zig", &lang_hub);
    defer ws.deinit();

    var win = try Window.create(gpa, &ws, .{}, .{ .font_store = &font_store });
    defer win.destroy();

    std.debug.print("done\n", .{});
}

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
rcb: ?*RenderCallbacks,
line_size_list: LineSizeList,
defaults: Defaults,

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions, super_market: SuperMarket) !*Window {
    var self = try a.create(@This());
    self.* = .{
        .a = a,
        .ws = ws,
        .attr = .{
            .pos = opts.pos,
            .padding = if (opts.padding) |p| p else Attributes.Padding{},
            .bounds = if (opts.bounds) |b| b else Attributes.Bounds{},
            .bounded = if (opts.bounds) |_| true else false,
        },
        .rcb = opts.render_callbacks,
        .line_size_list = try LineSizeList.initCapacity(a, ws.buf.ropeman.getNumOfLines()),
        .defaults = Defaults{},
    };

    try self.createInitialLineSizeList(super_market);

    return self;
}

pub fn destroy(self: *@This()) void {
    self.line_size_list.deinit(self.a);
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Create Line Size List

fn createInitialLineSizeList(self: *@This(), super_market: SuperMarket) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.createInitialLineSizeList()", 0xFF0000);
    defer zone.End();

    const font = super_market.font_store.getDefaultFont() orelse unreachable;
    const font_size = self.defaults.font_size;

    const default_glyph_data = font.glyph_map.get('?') orelse unreachable;

    for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
        var line_width: f32 = 0;
        var iter = try WindowSource.LineIterator.init(self.ws, linenr, 0);
        while (iter.next(self.ws.cap_list.items[linenr])) |result| {
            const glyph = font.glyph_map.get(result.code_point) orelse default_glyph_data;
            const scale_factor: f32 = font_size / font.base_size;
            var width = if (glyph.advanceX != 0) glyph.advanceX else glyph.width + glyph.offsetX;
            width = width * scale_factor;
            line_width += width;
        }
        try self.line_size_list.append(self.a, .{ .width = line_width, .height = font_size });
    }
}

test createInitialLineSizeList {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    var font_store = try createMockFontStore(testing_allocator);
    defer font_store.deinit();

    var ws = try WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
    defer ws.deinit();
    try eqStr("const a = 10;\nvar not_false = true;\n", ws.contents);

    {
        var win = try Window.create(testing_allocator, &ws, .{}, .{ .font_store = &font_store });
        defer win.destroy();

        try eq(3, win.line_size_list.items.len);
        try eq(LineSize{ .width = 13 * 15, .height = 40 }, win.line_size_list.items[0]);
        try eq(LineSize{ .width = 21 * 15, .height = 40 }, win.line_size_list.items[1]);
        try eq(LineSize{ .width = 0, .height = 40 }, win.line_size_list.items[2]);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const LineSizeList = std.ArrayListUnmanaged(LineSize);
const LineSize = struct {
    width: f32,
    height: f32,
};

const Defaults = struct {
    font_size: f32 = 40,
    color: u32 = 0xF5F5F5F5,
};

const SpawnOptions = struct {
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,

    render_callbacks: ?*RenderCallbacks = null,
};

const Attributes = struct {
    pos: Position,
    padding: Padding,
    bounds: Bounds,
    bounded: bool,

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
};

////////////////////////////////////////////////////////////////////////////////////////////// SuperMarket

const SuperMarket = struct {
    font_store: *FontStore,
};

fn createMockFontStore(a: Allocator) !FontStore {
    var font_store = try FontStore.init(a);
    try font_store.addNewFont("Test", 40);
    for (32..126) |i| try font_store.addGlyphDataToFont("Test", @intCast(i), .{ .offsetX = 0, .width = 1.1e1, .advanceX = 15 });
    return font_store;
}

////////////////////////////////////////////////////////////////////////////////////////////// Render Callbacks

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
