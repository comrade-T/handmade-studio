const WindowCache = @This();
const std = @import("std");
const ztracy = @import("ztracy");
const Window = @import("Window.zig");

const Allocator = std.mem.Allocator;
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

fn init(a: Allocator, win: *const Window) !WindowCache {
    const default_glyph = undefined;

    const num_of_lines = win.ws.buf.ropeman.getNumOfLines();
    var self = WindowCache{ .line_size_list = LineSizeList.initCapacity(a, num_of_lines) };

    for (0..num_of_lines) |linenr| {
        const line_width, const line_height = calculateLineSize(win, linenr, default_glyph);
        try self.line_size_list.append(self.a, LineSize{
            .width = line_width,
            .height = line_height,
        });
        self.width = @max(self.cached.width, line_width);
        self.height += line_height;
    }

    return self;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const LineIterator = Window.WindowSource.LineIterator;
const StyleStore = Window.StyleStore;
const StyleKey = StyleStore.StyleKey;
const Font = Window.FontStore.Font;
const GlyphData = Window.FontStore.Font.GlyphData;

fn calculateLineSize(win: *const Window, linenr: usize, style_store: *const StyleStore, default_font: *const Font, default_glyph: GlyphData) struct { usize, usize } {
    var line_width: f32 = 0;
    var line_height: f32 = 0;
    var iter = try LineIterator.init(win.ws, linenr);
    while (iter.next(win.ws.cap_list.items[linenr])) |r| {
        const font = getFont(win, r, style_store) orelse default_font;
        const font_size = getFontSize(win, r, style_store) orelse win.defaults.font_size;
        const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += width;
        line_height = @max(line_height, font_size);
    }
    return .{ line_width, line_height };
}

fn getFontSize(win: *const Window, r: LineIterator.Result, style_store: *const StyleStore) ?f32 {
    var i: usize = r.ids.len;
    while (i > 0) {
        i -= 1;
        const ids = r.ids[i];
        for (win.subscribed_style_sets.items) |styleset_id| {
            const key = StyleKey{ .query_id = ids.query_id, .capture_id = ids.capture_id, .styleset_id = styleset_id };
            if (style_store.getFontSize(key)) |font_size| return font_size;
        }
    }
}

fn getFont(win: *const Window, r: LineIterator.Result, style_store: *const StyleStore) ?*const Font {
    var i: usize = r.ids.len;
    while (i > 0) {
        i -= 1;
        const ids = r.ids[i];
        for (win.subscribed_style_sets.items) |styleset_id| {
            const key = StyleKey{ .query_id = ids.query_id, .capture_id = ids.capture_id, .styleset_id = styleset_id };
            if (style_store.getFont(key)) |f| return f;
        }
    }
}

fn calculateGlyphWidth(font: *const Font, font_size: f32, code_point: u21, default_glyph: GlyphData) f32 {
    const glyph = font.glyph_map.get(code_point) orelse default_glyph;
    const scale_factor: f32 = font_size / font.base_size;
    const width = if (glyph.advanceX != 0) glyph.advanceX else glyph.width + glyph.offsetX;
    return width * scale_factor;
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.debug.print("hello\n", .{});
}
