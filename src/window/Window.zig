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

pub const LangSuite = @import("LangSuite");
pub const WindowSource = @import("WindowSource");
pub const FontStore = @import("FontStore");
pub const ColorschemeStore = @import("ColorschemeStore");
pub const StyleStore = @import("StyleStore");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
rcb: ?*const RenderCallbacks,
cached: WindowCache = undefined,
defaults: Defaults,
subscribed_style_sets: SubscribedStyleSets,

const SubscribedStyleSets = std.ArrayListUnmanaged(u16);

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions, style_store: *const StyleStore) !*Window {
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
        .defaults = opts.defaults,
        .subscribed_style_sets = SubscribedStyleSets{},
    };
    self.cached = try WindowCache.init(self.a, self, style_store);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.cached.deinit(self.a);
    self.subscribed_style_sets.deinit(self.a);
    self.a.destroy(self);
}

pub fn subscribeToStyleSet(self: *@This(), styleset_id: u16) !void {
    try self.subscribed_style_sets.append(self.a, styleset_id);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), style_store: *const StyleStore, view: ScreenView) void {

    ///////////////////////////// Profiling

    const render_zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
    defer render_zone.End();

    var chars_rendered: i64 = 0;
    defer ztracy.PlotI("chars_rendered", chars_rendered);

    ///////////////////////////// Temporary Setup

    const default_font = style_store.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const colorscheme = style_store.colorscheme_store.getDefaultColorscheme() orelse unreachable;

    assert(self.rcb != null);
    const rcb = self.rcb orelse return;

    ///////////////////////////// Culling & Render

    if (self.attr.pos.x > view.end.x) return;
    if (self.attr.pos.y > view.end.y) return;

    if (self.attr.pos.x + self.cached.width < view.start.x) return;
    if (self.attr.pos.y + self.cached.height < view.start.y) return;

    var x: f32 = self.attr.pos.x;
    var y: f32 = self.attr.pos.y;

    for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
        defer x = self.attr.pos.x;
        defer y += self.cached.line_sizes.items[linenr].height;

        if (y > view.end.y) return;
        if (x + self.cached.line_sizes.items[linenr].width < view.start.x) continue;
        if (y + self.cached.line_sizes.items[linenr].height < view.start.y) continue;

        var content_buf: [1024]u8 = undefined;
        var iter = WindowSource.LineIterator.init(self.ws, linenr, &content_buf) catch continue;
        while (iter.next(self.ws.cap_list.items[linenr])) |r| {
            const font = getStyleFromStore(*const FontStore.Font, self, r, style_store, StyleStore.getFont) orelse default_font;
            const font_size = getStyleFromStore(f32, self, r, style_store, StyleStore.getFontSize) orelse self.defaults.font_size;

            const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
            defer x += width;

            if (x > view.end.x) break;
            if (x + width < view.start.x) continue;

            var color = self.defaults.color;

            var i: usize = r.ids.len;
            while (i > 0) {
                i -= 1;
                const ids = r.ids[i];
                const group_name = self.ws.ls.?.queries.values()[ids.query_id].query.getCaptureNameForId(ids.capture_id);
                if (colorscheme.get(group_name)) |c| {
                    color = c;
                    break;
                }
            }

            rcb.drawCodePoint(font, r.code_point, x, y, font_size, color);
            chars_rendered += 1;
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowCache

const WindowCache = struct {
    width: f32 = 0,
    height: f32 = 0,
    line_sizes: LineSizeList,

    const LineSizeList = std.ArrayListUnmanaged(LineSize);
    const LineSize = struct { width: f32, height: f32 };

    fn init(a: Allocator, win: *const Window, style_store: *const StyleStore) !WindowCache {
        const default_font = style_store.font_store.getDefaultFont() orelse unreachable;
        const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

        const num_of_lines = win.ws.buf.ropeman.getNumOfLines();
        var self = WindowCache{ .line_sizes = try LineSizeList.initCapacity(a, num_of_lines) };

        for (0..num_of_lines) |linenr| {
            const line_width, const line_height = try calculateLineSize(win, linenr, style_store, default_font, default_glyph);
            try self.line_sizes.append(a, LineSize{
                .width = line_width,
                .height = line_height,
            });
            self.width = @max(self.width, line_width);
            self.height += line_height;
        }

        return self;
    }

    fn deinit(self: *@This(), a: Allocator) void {
        self.line_sizes.deinit(a);
    }

    test WindowCache {
        const style_store = try StyleStore.createStyleStoreForTesting(testing_allocator);
        defer StyleStore.freeTestStyleStore(testing_allocator, style_store);

        var lang_hub = try Window.LangSuite.LangHub.init(testing_allocator);
        defer lang_hub.deinit();

        var ws = try Window.WindowSource.init(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
        defer ws.deinit();
        try eqStr("const a = 10;\nvar not_false = true;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));

        {
            var win = try Window.create(testing_allocator, &ws, .{}, style_store);
            defer win.destroy();

            try eq(3, win.cached.line_sizes.items.len);
            try eq(21 * 15, win.cached.width);
            try eq(3 * 40, win.cached.height);
            try eq(LineSize{ .width = 13 * 15, .height = 40 }, win.cached.line_sizes.items[0]);
            try eq(LineSize{ .width = 21 * 15, .height = 40 }, win.cached.line_sizes.items[1]);
            try eq(LineSize{ .width = 0, .height = 40 }, win.cached.line_sizes.items[2]);
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Styles & Size Calculations

const Font = FontStore.Font;
const GlyphData = Font.GlyphData;

fn calculateLineSize(win: *const Window, linenr: usize, style_store: *const StyleStore, default_font: *const Font, default_glyph: GlyphData) !struct { f32, f32 } {
    var line_width: f32 = 0;
    var line_height: f32 = win.defaults.font_size;
    var content_buf: [1024]u8 = undefined;
    var iter = try WindowSource.LineIterator.init(win.ws, linenr, &content_buf);
    while (iter.next(win.ws.cap_list.items[linenr])) |r| {
        const font = getStyleFromStore(*const Font, win, r, style_store, StyleStore.getFont) orelse default_font;
        const font_size = getStyleFromStore(f32, win, r, style_store, StyleStore.getFontSize) orelse win.defaults.font_size;

        const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += width;
        line_height = @max(line_height, font_size);
    }
    return .{ line_width, line_height };
}

fn getStyleFromStore(T: type, win: *const Window, r: WindowSource.LineIterator.Result, style_store: *const StyleStore, cb: anytype) ?T {
    var i: usize = r.ids.len;
    while (i > 0) {
        i -= 1;
        const ids = r.ids[i];
        for (win.subscribed_style_sets.items) |styleset_id| {
            const key = StyleStore.StyleKey{
                .query_id = ids.query_id,
                .capture_id = ids.capture_id,
                .styleset_id = styleset_id,
            };
            if (cb(style_store, key)) |value| return value;
        }
    }
    return null;
}

fn calculateGlyphWidth(font: *const Font, font_size: f32, code_point: u21, default_glyph: GlyphData) f32 {
    const glyph = font.glyph_map.get(code_point) orelse default_glyph;
    const scale_factor: f32 = font_size / font.base_size;
    const width = if (glyph.advanceX != 0) glyph.advanceX else glyph.width + glyph.offsetX;
    return width * scale_factor;
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const Defaults = struct {
    font_size: f32 = 40,
    color: u32 = 0xF5F5F5F5,
};

const SpawnOptions = struct {
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,
    defaults: Defaults = Defaults{},

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

////////////////////////////////////////////////////////////////////////////////////////////// Render Callbacks

pub const RenderCallbacks = struct {
    drawCodePoint: *const fn (font: *const FontStore.Font, code_point: u21, x: f32, y: f32, font_size: f32, color: u32) void,
};

const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};

////////////////////////////////////////////////////////////////////////////////////////////// Reference for Testing

test {
    std.testing.refAllDeclsRecursive(WindowCache);
}
