const WindowCache = @This();
const std = @import("std");
const ztracy = @import("ztracy");
const Window = @import("Window.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

width: f32,
height: f32,
lines: LineSizeList,

//////////////////////////////////////////////////////////////////////////////////////////////

const Font = Window.FontStore.Font;
const GlyphData = Window.FontStore.Font.GlyphData;
const WindowSource = Window.WindowSource;
const IterResult = WindowSource.LineIterator.Result;

fn calculateGlyphWidth(font: *const Font, font_size: f32, code_point: u21, default_glyph: GlyphData) f32 {
    const glyph = font.glyph_map.get(code_point) orelse default_glyph;
    const scale_factor: f32 = font_size / font.base_size;
    const width = if (glyph.advanceX != 0) glyph.advanceX else glyph.width + glyph.offsetX;
    return width * scale_factor;
}

const Supermarket = Window.Supermarket;

// TODO: extract this to smaller functions / methods
fn createInitialLineSizeList(self: *WindowCache, win: *Window, supermarket: Supermarket) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.createInitialLineSizeList()", 0xFF0000);
    defer zone.End();

    const font = supermarket.font_store.getDefaultFont() orelse unreachable;
    const font_size = win.defaults.font_size;
    const default_glyph = font.glyph_map.get('?') orelse unreachable; // TODO: get data from default Raylib font

    for (0..win.ws.buf.ropeman.getNumOfLines()) |linenr| {
        var line_width: f32 = 0;
        var iter = try WindowSource.LineIterator.init(win.ws, linenr);
        while (iter.next(win.ws.cap_list.items[linenr])) |r| {
            const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
            line_width += width;
        }
        try self.lines.append(win.a, .{ .width = line_width, .height = font_size });
        self.width = @max(self.width, line_width);
        self.height += font_size;
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const LineSizeList = std.ArrayListUnmanaged(LineSize);
const LineSize = struct {
    width: f32,
    height: f32,
};

test {
    try std.testing.expectEqual(1, 1);
}
