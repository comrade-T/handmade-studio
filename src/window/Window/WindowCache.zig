const WindowCache = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Window = @import("../Window.zig");
const WindowSource = Window.WindowSource;
const RenderMall = Window.RenderMall;
const Font = Window.FontStore.Font;
const GlyphData = Font.GlyphData;

//////////////////////////////////////////////////////////////////////////////////////////////

width: f32 = 0,
height: f32 = 0,
line_info: LineInfoList,

const LineInfoList = std.ArrayListUnmanaged(LineInfo);
const LineInfo = struct {
    width: f32,
    height: f32,
    base_line: f32,
};

pub fn init(a: Allocator, win: *const Window, mall: *const RenderMall) !WindowCache {
    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const num_of_lines = win.ws.buf.ropeman.getNumOfLines();
    var self = WindowCache{ .line_info = try LineInfoList.initCapacity(a, num_of_lines) };

    for (0..num_of_lines) |linenr| {
        const info = try calculateLineInfo(win, linenr, mall, default_font, default_glyph);
        try self.line_info.append(a, info);

        self.width = @max(self.width, info.width);
        self.height += info.height;
    }

    return self;
}

pub fn deinit(self: *@This(), a: Allocator) void {
    self.line_info.deinit(a);
}

fn updateWidthHeight(self: *@This()) void {
    self.width = 0;
    self.height = 0;
    for (self.line_info.items) |info| {
        self.width = @max(self.width, info.width);
        self.height += info.height;
    }
}

fn calculateLineInfo(
    win: *const Window,
    linenr: usize,
    mall: *const RenderMall,
    default_font: *const Font,
    default_glyph: GlyphData,
) !LineInfo {
    var line_width: f32, var line_height: f32 = .{ 0, win.defaults.font_size };
    var min_base_line: f32, var max_base_line: f32, var max_font_size: f32 = .{ 0, 0, 0 };

    var content_buf: [1024]u8 = undefined;
    var iter = try WindowSource.LineIterator.init(win.ws, linenr, &content_buf);
    const captures: []WindowSource.StoredCapture = if (win.ws.ls != null) win.ws.cap_list.items[linenr] else &.{};
    while (iter.next(captures)) |r| {

        // get font & font_size
        const font = Window.getStyleFromStore(*const Font, win, r, mall, RenderMall.getFont) orelse default_font;
        const font_size = Window.getStyleFromStore(f32, win, r, mall, RenderMall.getFontSize) orelse win.defaults.font_size;
        assert(font_size > 0);

        // base_line management
        manageBaseLineInformation(font, font_size, &max_font_size, &min_base_line, &max_base_line);

        // calculate width & height
        const glyph_width = RenderMall.calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += glyph_width;
        line_height = @max(line_height, font_size);
    }

    // update line_height if needed
    line_height += max_base_line - min_base_line;

    return LineInfo{
        .width = line_width,
        .height = line_height,
        .base_line = min_base_line,
    };
}

fn manageBaseLineInformation(
    font: *const Font,
    font_size: f32,
    max_font_size: *f32,
    min_base_line: *f32,
    max_base_line: *f32,
) void {
    const adapted_base_line = font.getAdaptedBaseLine(font_size);

    if (font_size < max_font_size.*) return;

    if (font_size > max_font_size.*) {
        max_font_size.* = font_size;
        max_base_line.* = adapted_base_line;
        min_base_line.* = adapted_base_line;
        return;
    }

    min_base_line.* = @min(min_base_line.*, adapted_base_line);
    max_base_line.* = @max(max_base_line.*, adapted_base_line);
}

pub fn updateCacheLines(
    self: *@This(),
    win: *const Window,
    ri: WindowSource.ReplaceInfo,
    mall: *const RenderMall,
    default_font: *const Font,
    default_glyph: Font.GlyphData,
) !void {
    assert(ri.end_line >= ri.start_line);

    var replacements = try std.ArrayList(LineInfo).initCapacity(win.a, ri.end_line - ri.start_line + 1);
    defer replacements.deinit();

    for (ri.start_line..ri.end_line + 1) |linenr| {
        const info = try calculateLineInfo(win, linenr, mall, default_font, default_glyph);
        try replacements.append(info);
    }
    try self.line_info.replaceRange(win.a, ri.replace_start, ri.replace_len, replacements.items);

    self.updateWidthHeight();
}
