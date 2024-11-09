const WindowCache = @This();
const std = @import("std");
const ztracy = @import("ztracy");
const Window = @import("Window.zig");

const Allocator = std.mem.Allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

width: f32 = 0,
height: f32 = 0,
line_size_list: LineSizeList,

const LineSizeList = std.ArrayListUnmanaged(LineSize);
const LineSize = struct { width: f32, height: f32 };

pub fn init(a: Allocator, win: *const Window, style_store: *const StyleStore) !WindowCache {
    const default_font = style_store.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const num_of_lines = win.ws.buf.ropeman.getNumOfLines();
    var self = WindowCache{ .line_size_list = try LineSizeList.initCapacity(a, num_of_lines) };

    for (0..num_of_lines) |linenr| {
        const line_width, const line_height = try calculateLineSize(win, linenr, style_store, default_font, default_glyph);
        try self.line_size_list.append(a, LineSize{
            .width = line_width,
            .height = line_height,
        });
        self.width = @max(self.width, line_width);
        self.height += line_height;
    }

    return self;
}

pub fn deinit(self: *@This(), a: Allocator) void {
    self.line_size_list.deinit(a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const LineIterator = Window.WindowSource.LineIterator;
const StyleStore = Window.StyleStore;
const StyleKey = StyleStore.StyleKey;
const Font = Window.FontStore.Font;
const GlyphData = Window.FontStore.Font.GlyphData;

fn calculateLineSize(win: *const Window, linenr: usize, style_store: *const StyleStore, default_font: *const Font, default_glyph: GlyphData) !struct { f32, f32 } {
    var line_width: f32 = 0;
    var line_height: f32 = win.defaults.font_size;
    var iter = try LineIterator.init(win.ws, linenr);
    while (iter.next(win.ws.cap_list.items[linenr])) |r| {
        const font = getStyleFromStore(*const Font, win, r, style_store, StyleStore.getFont) orelse default_font;
        const font_size = getStyleFromStore(f32, win, r, style_store, StyleStore.getFontSize) orelse win.defaults.font_size;

        const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += width;
        line_height = @max(line_height, font_size);
    }
    return .{ line_width, line_height };
}

fn getStyleFromStore(T: type, win: *const Window, r: LineIterator.Result, style_store: *const StyleStore, cb: anytype) ?T {
    var i: usize = r.ids.len;
    while (i > 0) {
        i -= 1;
        const ids = r.ids[i];
        for (win.subscribed_style_sets.items) |styleset_id| {
            const key = StyleKey{
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

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
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

        try eq(3, win.cached.line_size_list.items.len);
        try eq(21 * 15, win.cached.width);
        try eq(3 * 40, win.cached.height);
        try eq(LineSize{ .width = 13 * 15, .height = 40 }, win.cached.line_size_list.items[0]);
        try eq(LineSize{ .width = 21 * 15, .height = 40 }, win.cached.line_size_list.items[1]);
        try eq(LineSize{ .width = 0, .height = 40 }, win.cached.line_size_list.items[2]);
    }
}
