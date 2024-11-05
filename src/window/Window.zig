// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const Window = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite");
pub const WindowSource = @import("WindowSource");
const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
rcb: ?*const RenderCallbacks,
cached: CachedSizes,
defaults: Defaults,

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions, supermarket: Supermarket) !*Window {
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
        .cached = CachedSizes{
            .width = 0,
            .height = 0,
            .lines = try LineSizeList.initCapacity(a, ws.buf.ropeman.getNumOfLines()),
        },
        .defaults = Defaults{},
    };

    try self.createInitialLineSizeList(supermarket);

    return self;
}

pub fn destroy(self: *@This()) void {
    self.cached.lines.deinit(self.a);
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), supermarket: Supermarket, view: ScreenView) void {
    const zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
    defer zone.End();

    assert(self.rcb != null);
    const rcb = self.rcb orelse return;

    const font = supermarket.font_store.getDefaultFont() orelse unreachable;
    const font_size = self.defaults.font_size;
    const default_glyph_data = font.glyph_map.get('?') orelse unreachable; // TODO: get data from default Raylib font

    const colorscheme = supermarket.colorscheme_store.getDefaultColorscheme() orelse unreachable;

    var chars_rendered: i64 = 0;
    defer ztracy.PlotI("chars_rendered", chars_rendered);

    /////////////////////////////

    if (self.attr.pos.x > view.end.x) return;
    if (self.attr.pos.y > view.end.y) return;

    if (self.attr.pos.x + self.cached.width < view.start.x) return;
    if (self.attr.pos.y + self.cached.height < view.start.y) return;

    var x: f32 = self.attr.pos.x;
    var y: f32 = self.attr.pos.y;

    for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
        defer x = self.attr.pos.x;
        defer y += font_size;

        if (y > view.end.y) return;
        if (x + self.cached.lines.items[linenr].width < view.start.x) continue;
        if (y + self.cached.lines.items[linenr].height < view.start.y) continue;

        var iter = WindowSource.LineIterator.init(self.ws, linenr) catch continue;
        while (iter.next(self.ws.cap_list.items[linenr])) |result| {
            const width = calculateGlyphWidth(font, font_size, result, default_glyph_data);
            defer x += width;

            if (x > view.end.x) break;
            if (x + width < view.start.x) continue;

            var color = self.defaults.color;

            var i: usize = result.ids.len;
            while (i > 0) {
                i -= 1;
                const ids = result.ids[i];
                const group_name = self.ws.ls.?.queries.values()[ids.query_id].query.getCaptureNameForId(ids.capture_id);
                if (colorscheme.get(group_name)) |c| {
                    color = c;
                    break;
                }
            }

            rcb.drawCodePoint(font, result.code_point, x, y, font_size, color);
            chars_rendered += 1;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Create Line Size List

fn calculateGlyphWidth(font: *const FontStore.Font, font_size: f32, iter_result: WindowSource.LineIterator.Result, default_glyph_data: FontStore.Font.GlyphData) f32 {
    const glyph = font.glyph_map.get(iter_result.code_point) orelse default_glyph_data;
    const scale_factor: f32 = font_size / font.base_size;
    const width = if (glyph.advanceX != 0) glyph.advanceX else glyph.width + glyph.offsetX;
    return width * scale_factor;
}

fn createInitialLineSizeList(self: *@This(), supermarket: Supermarket) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.createInitialLineSizeList()", 0xFF0000);
    defer zone.End();

    const font = supermarket.font_store.getDefaultFont() orelse unreachable;
    const font_size = self.defaults.font_size;
    const default_glyph_data = font.glyph_map.get('?') orelse unreachable; // TODO: get data from default Raylib font

    for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
        var line_width: f32 = 0;
        var iter = try WindowSource.LineIterator.init(self.ws, linenr);
        while (iter.next(self.ws.cap_list.items[linenr])) |result| {
            const width = calculateGlyphWidth(font, font_size, result, default_glyph_data);
            line_width += width;
        }
        try self.cached.lines.append(self.a, .{ .width = line_width, .height = font_size });
        self.cached.width = @max(self.cached.width, line_width);
        self.cached.height += font_size;
    }
}

test createInitialLineSizeList {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    const supermarket = try createMockSuperMarket(testing_allocator);
    defer deinitSuperMarket(testing_allocator, supermarket);

    var ws = try WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
    defer ws.deinit();
    try eqStr("const a = 10;\nvar not_false = true;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));

    {
        var win = try Window.create(testing_allocator, &ws, .{}, supermarket);
        defer win.destroy();

        try eq(3, win.cached.lines.items.len);
        try eq(21 * 15, win.cached.width);
        try eq(3 * 40, win.cached.height);
        try eq(LineSize{ .width = 13 * 15, .height = 40 }, win.cached.lines.items[0]);
        try eq(LineSize{ .width = 21 * 15, .height = 40 }, win.cached.lines.items[1]);
        try eq(LineSize{ .width = 0, .height = 40 }, win.cached.lines.items[2]);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const CachedSizes = struct {
    width: f32,
    height: f32,
    lines: LineSizeList,
};

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

    render_callbacks: ?*const RenderCallbacks = null,
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

pub const Supermarket = struct {
    font_store: *FontStore,
    colorscheme_store: *ColorschemeStore,
};

fn deinitSuperMarket(a: Allocator, sp: Supermarket) void {
    sp.font_store.deinit();
    sp.colorscheme_store.deinit();
    a.destroy(sp.font_store);
    a.destroy(sp.colorscheme_store);
}

fn createMockSuperMarket(a: Allocator) !Supermarket {
    const font_store = try a.create(FontStore);
    font_store.* = try createMockFontStore(a);

    const colorscheme_store = try a.create(ColorschemeStore);
    colorscheme_store.* = try ColorschemeStore.init(a);
    try colorscheme_store.initializeNightflyColorscheme();

    return Supermarket{
        .font_store = font_store,
        .colorscheme_store = colorscheme_store,
    };
}

fn createMockFontStore(a: Allocator) !FontStore {
    var font_store = try FontStore.init(a);
    try font_store.addNewFont(null, "Test", 40);
    const f = font_store.getDefaultFont() orelse unreachable;
    for (32..126) |i| try f.addGlyph(a, @intCast(i), .{ .offsetX = 0, .width = 1.1e1, .advanceX = 15 });
    return font_store;
}

////////////////////////////////////////////////////////////////////////////////////////////// Render Callbacks

pub const RenderCallbacks = struct {
    drawCodePoint: *const fn (font: *const FontStore.Font, code_point: u21, x: f32, y: f32, font_size: f32, color: u32) void,
};

const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};
