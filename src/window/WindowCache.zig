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

fn calculateLineSize(win: *const Window, linenr: usize, default_glyph: GlyphData) struct { usize, usize } {
    const font = undefined;
    const font_size = undefined;

    var line_width: f32 = 0;
    var iter = try WindowSource.LineIterator.init(win.ws, linenr);
    while (iter.next(win.ws.cap_list.items[linenr])) |r| {
        const width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += width;
    }
    const line_height = font_size;

    return .{ line_width, line_height };
}

//////////////////////////////////////////////////////////////////////////////////////////////
