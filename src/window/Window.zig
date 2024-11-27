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
pub const RenderMall = @import("RenderMall");
pub const FontStore = RenderMall.FontStore;
pub const ColorschemeStore = RenderMall.ColorschemeStore;
const ScreenView = RenderMall.ScreenView;

const CursorManager = @import("CursorManager");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
cached: WindowCache = undefined,
defaults: Defaults,
subscribed_style_sets: SubscribedStyleSets,
cursor_manager: *CursorManager,

const SubscribedStyleSets = std.ArrayListUnmanaged(u16);

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions, mall: *const RenderMall) !*Window {
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
        .defaults = opts.defaults,
        .subscribed_style_sets = SubscribedStyleSets{},
        .cursor_manager = try CursorManager.create(self.a),
    };

    if (opts.subscribed_style_sets) |slice| try self.subscribed_style_sets.appendSlice(self.a, slice);

    // this must be called last
    self.cached = try WindowCache.init(self.a, self, mall);

    return self;
}

pub fn destroy(self: *@This()) void {
    self.cached.deinit(self.a);
    self.subscribed_style_sets.deinit(self.a);
    self.cursor_manager.destroy();
    self.a.destroy(self);
}

// pub fn subscribeToStyleSet(self: *@This(), styleset_id: u16) !void {
//     try self.subscribed_style_sets.append(self.a, styleset_id);
// }

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), mall: *const RenderMall, view: ScreenView, render_callbacks: RenderMall.RenderCallbacks) void {

    ///////////////////////////// Profiling

    const render_zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
    defer render_zone.End();

    var chars_rendered: i64 = 0;
    defer ztracy.PlotI("chars_rendered", chars_rendered);

    ///////////////////////////// Temporary Setup

    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const colorscheme = mall.colorscheme_store.getDefaultColorscheme() orelse unreachable;

    ///////////////////////////// Culling & Render

    if (self.isOutOfView(view)) return;

    var renderer = Renderer{
        .win = self,
        .view = view,
        .render_callbacks = render_callbacks,
        .char_x = self.attr.pos.x,
        .line_y = self.attr.pos.y,
    };

    for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
        renderer.updateLinenr(linenr);
        defer renderer.nextLine();

        if (renderer.lineYBelowView()) return;
        if (renderer.lineYAboveView() or renderer.lineStartPointOutOfView()) continue;

        var colnr: usize = 0;
        renderer.updateColnr(colnr);

        var content_buf: [1024]u8 = undefined;
        var iter = WindowSource.LineIterator.init(self.ws, linenr, &content_buf) catch continue;
        const captures: []WindowSource.StoredCapture = if (self.ws.ls != null) self.ws.cap_list.items[linenr] else &.{};
        while (iter.next(captures)) |r| {
            defer {
                colnr += 1;
                renderer.updateColnr(colnr);
            }

            const font = getStyleFromStore(*const FontStore.Font, self, r, mall, RenderMall.getFont) orelse default_font;
            const font_size = getStyleFromStore(f32, self, r, mall, RenderMall.getFontSize) orelse self.defaults.font_size;

            const char_width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
            defer renderer.char_x += char_width;

            if (renderer.charStartsAfterViewEnds()) break;
            if (renderer.charEndsBeforeViewStart(char_width)) continue;

            assert(renderer.lineHeight() >= font_size);
            const color = self.getCharColor(r, colorscheme);
            renderer.updateCharY(font, font_size);

            render_callbacks.drawCodePoint(font, r.code_point, renderer.char_x, renderer.char_y, font_size, color);
            chars_rendered += 1;

            defer renderer.renderCursorAndSelectionPartOne(font_size, char_width);
        }

        if (self.cursor_manager.cursor_mode == .range) { // .range
            const line_width = self.cached.line_info.items[linenr].width;
            for (self.cursor_manager.cursors.values()) |*cursor| {
                if (cursor.start.line < linenr and cursor.end.line > linenr) {
                    render_callbacks.drawRectangle(self.attr.pos.x, renderer.line_y, line_width, renderer.lineHeight(), self.defaults.selection_color);
                }
            }
        }

        if (renderer.last_char_info) |info| { // cursors: if cursor at line end
            defer renderer.last_char_info = null;
            for (self.cursor_manager.cursors.values()) |*cursor| {
                const anchor = cursor.activeAnchor(self.cursor_manager);
                if (anchor.line != linenr or anchor.col != colnr) continue;
                render_callbacks.drawRectangle(info.x + info.width, renderer.line_y, info.width, info.font_size, self.defaults.color);
            }
            continue;
        }

        if (colnr == 0) { // cursors: if line is empty
            for (self.cursor_manager.cursors.values()) |*cursor| {
                const anchor = cursor.activeAnchor(self.cursor_manager);
                if (anchor.line != linenr) continue;
                const char_width = calculateGlyphWidth(default_font, self.defaults.font_size, ' ', default_glyph);
                render_callbacks.drawRectangle(renderer.char_x, renderer.line_y, char_width, renderer.lineHeight(), self.defaults.color);
            }
            continue;
        }
    }
}

fn isOutOfView(self: *@This(), view: ScreenView) bool {
    if (self.attr.pos.x > view.end.x) return true;
    if (self.attr.pos.y > view.end.y) return true;

    if (self.attr.pos.x + self.cached.width < view.start.x) return true;
    if (self.attr.pos.y + self.cached.height < view.start.y) return true;

    return false;
}

fn getCharColor(self: *@This(), r: WindowSource.LineIterator.Result, colorscheme: *const ColorschemeStore.Colorscheme) u32 {
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
    return color;
}

////////////////////////////////////////////////////////////////////////////////////////////// Renderer

const LastestRenderedCharInfo = ?struct { x: f32, width: f32, font_size: f32 };

const Renderer = struct {
    win: *Window,
    view: ScreenView,
    render_callbacks: RenderMall.RenderCallbacks,

    linenr: usize = 0,
    colnr: usize = 0,

    char_x: f32,
    line_y: f32,

    char_y: f32 = 0,

    // selection related

    last_char_info: LastestRenderedCharInfo = null,
    selection_start_x: ?f32 = null,

    ///////////////////////////// updates

    fn updateLinenr(self: *@This(), linenr: usize) void {
        self.linenr = linenr;
    }

    fn updateColnr(self: *@This(), colnr: usize) void {
        self.colnr = colnr;
    }

    fn nextLine(self: *@This()) void {
        self.char_x = self.win.attr.pos.x;
        self.line_y += self.lineHeight();
    }

    fn updateCharY(self: *@This(), font: *const FontStore.Font, font_size: f32) void {
        const height_deficit = self.lineHeight() - font_size;
        const char_base = font.getAdaptedBaseLine(font_size);
        const char_shift = self.baseLine() - (height_deficit + char_base);
        self.char_y = self.line_y + height_deficit + char_shift;
    }

    ///////////////////////////// getters

    fn lineHeight(self: *@This()) f32 {
        return self.win.cached.line_info.items[self.linenr].height;
    }

    fn baseLine(self: *@This()) f32 {
        return self.win.cached.line_info.items[self.linenr].base_line;
    }

    ///////////////////////////// checkers

    fn lineYAboveView(self: *@This()) bool {
        return self.line_y + self.lineHeight() < self.view.start.y;
    }

    fn lineYBelowView(self: *@This()) bool {
        return self.line_y > self.view.end.y;
    }

    fn lineStartPointOutOfView(self: *@This()) bool {
        const x = self.char_x + self.win.cached.line_info.items[self.linenr].width < self.view.start.x;
        const y = self.line_y + self.win.cached.line_info.items[self.linenr].height < self.view.start.y;
        return x or y;
    }

    fn charStartsAfterViewEnds(self: *@This()) bool {
        return self.char_x > self.view.end.x;
    }

    fn charEndsBeforeViewStart(self: *@This(), char_width: f32) bool {
        return self.char_x + char_width < self.view.start.x;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// drawing

    /// This gets called right after rendering a character
    fn renderCursorAndSelectionPartOne(self: *@This(), font_size: f32, char_width: f32) void {
        self.last_char_info = .{ .x = self.char_x, .width = char_width, .font_size = font_size };

        for (self.win.cursor_manager.cursors.values()) |*cursor| { // .point
            const anchor = cursor.activeAnchor(self.win.cursor_manager);
            if (anchor.line != self.linenr or anchor.col != self.colnr) continue;
            self.render_callbacks.drawRectangle(self.char_x, self.char_y, char_width, font_size, self.win.defaults.color);
        }

        if (self.win.cursor_manager.cursor_mode == .range) { // .range
            const line_width = self.win.cached.line_info.items[self.linenr].width;

            for (self.win.cursor_manager.cursors.values()) |*cursor| {
                if (cursor.start.line == self.linenr and cursor.start.col == self.colnr) {
                    if (self.selection_start_x == null) self.selection_start_x = self.char_x;

                    if (cursor.end.line == self.linenr) continue;

                    // selection starts on this line but ends elsewhere
                    const width = line_width - (self.char_x - self.win.attr.pos.x);
                    self.render_callbacks.drawRectangle(self.char_x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                    continue;
                }

                if (cursor.end.line == self.linenr and cursor.end.col == self.colnr) {

                    // selection starts and ends on this line
                    if (self.selection_start_x) |start_x| {
                        const width = self.char_x + char_width - start_x;
                        self.render_callbacks.drawRectangle(start_x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                        continue;
                    }

                    // selection started elsewhere and ends here
                    const width = self.char_x + char_width - self.win.attr.pos.x;
                    self.render_callbacks.drawRectangle(self.win.attr.pos.x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                    continue;
                }
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn insertChars(self: *@This(), chars: []const u8, mall: *const RenderMall) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.insertChars()", 0x00AAFF);
    defer zone.End();

    const result = try self.ws.insertChars(self.a, chars, self.cursor_manager) orelse return;
    try self.processEditResult(result, mall);
}

pub fn deleteRanges(self: *@This(), mall: *const RenderMall, kind: WindowSource.DeleteRangesKind) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.deleteRanges()", 0x00AAFF);
    defer zone.End();

    const result = try self.ws.deleteRanges(self.a, self.cursor_manager, kind) orelse return;
    try self.processEditResult(result, mall);
}

fn processEditResult(self: *@This(), replace_infos: []const WindowSource.ReplaceInfo, mall: *const RenderMall) !void {
    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    defer self.a.free(replace_infos);
    for (replace_infos) |ri| try self.updateCacheLines(ri, mall, default_font, default_glyph);
}

fn updateCacheLines(self: *@This(), ri: WindowSource.ReplaceInfo, mall: *const RenderMall, default_font: *const Font, default_glyph: GlyphData) !void {
    assert(ri.end_line >= ri.start_line);

    var replacements = try std.ArrayList(WindowCache.LineInfo).initCapacity(self.a, ri.end_line - ri.start_line + 1);
    defer replacements.deinit();

    for (ri.start_line..ri.end_line + 1) |linenr| {
        const info = try calculateLineInfo(self, linenr, mall, default_font, default_glyph);
        try replacements.append(info);
    }
    try self.cached.line_info.replaceRange(self.a, ri.replace_start, ri.replace_len, replacements.items);
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowCache

const WindowCache = struct {
    width: f32 = 0,
    height: f32 = 0,
    line_info: LineInfoList,

    const LineInfoList = std.ArrayListUnmanaged(LineInfo);
    const LineInfo = struct {
        width: f32,
        height: f32,
        base_line: f32,
    };

    fn init(a: Allocator, win: *const Window, mall: *const RenderMall) !WindowCache {
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

    fn deinit(self: *@This(), a: Allocator) void {
        self.line_info.deinit(a);
    }

    test WindowCache {
        const mall = try RenderMall.createStyleStoreForTesting(testing_allocator);
        defer RenderMall.freeTestStyleStore(testing_allocator, mall);

        var lang_hub = try Window.LangSuite.LangHub.init(testing_allocator);
        defer lang_hub.deinit();

        var ws = try Window.WindowSource.create(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
        defer ws.destroy();
        try eqStr("const a = 10;\nvar not_false = true;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));

        {
            var win = try Window.create(testing_allocator, ws, .{}, mall);
            defer win.destroy();

            try eq(3, win.cached.line_info.items.len);
            try eq(21 * 15, win.cached.width);
            try eq(3 * 40, win.cached.height);
            try eq(LineInfo{ .base_line = 30, .width = 13 * 15, .height = 40 }, win.cached.line_info.items[0]);
            try eq(LineInfo{ .base_line = 30, .width = 21 * 15, .height = 40 }, win.cached.line_info.items[1]);
            try eq(LineInfo{ .base_line = 0, .width = 0, .height = 40 }, win.cached.line_info.items[2]);
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Styles & Size Calculations

const Font = FontStore.Font;
const GlyphData = Font.GlyphData;

fn calculateLineInfo(win: *const Window, linenr: usize, mall: *const RenderMall, default_font: *const Font, default_glyph: GlyphData) !WindowCache.LineInfo {
    var line_width: f32, var line_height: f32 = .{ 0, win.defaults.font_size };
    var min_base_line: f32, var max_base_line: f32, var max_font_size: f32 = .{ 0, 0, 0 };

    var content_buf: [1024]u8 = undefined;
    var iter = try WindowSource.LineIterator.init(win.ws, linenr, &content_buf);
    const captures: []WindowSource.StoredCapture = if (win.ws.ls != null) win.ws.cap_list.items[linenr] else &.{};
    while (iter.next(captures)) |r| {

        // get font & font_size
        const font = getStyleFromStore(*const Font, win, r, mall, RenderMall.getFont) orelse default_font;
        const font_size = getStyleFromStore(f32, win, r, mall, RenderMall.getFontSize) orelse win.defaults.font_size;
        assert(font_size > 0);

        // base_line management
        manageBaseLineInformation(font, font_size, &max_font_size, &min_base_line, &max_base_line);

        // calculate width & height
        const glyph_width = calculateGlyphWidth(font, font_size, r.code_point, default_glyph);
        line_width += glyph_width;
        line_height = @max(line_height, font_size);
    }

    // update line_height if needed
    line_height += max_base_line - min_base_line;

    return WindowCache.LineInfo{
        .width = line_width,
        .height = line_height,
        .base_line = min_base_line,
    };
}

fn manageBaseLineInformation(font: *const Font, font_size: f32, max_font_size: *f32, min_base_line: *f32, max_base_line: *f32) void {
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

fn getStyleFromStore(T: type, win: *const Window, r: WindowSource.LineIterator.Result, mall: *const RenderMall, cb: anytype) ?T {
    var i: usize = r.ids.len;
    while (i > 0) {
        i -= 1;
        const ids = r.ids[i];
        for (win.subscribed_style_sets.items) |styleset_id| {
            const key = RenderMall.StyleKey{
                .query_id = ids.query_id,
                .capture_id = ids.capture_id,
                .styleset_id = styleset_id,
            };
            if (cb(mall, key)) |value| return value;
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
    selection_color: u32 = 0xF5F5F533,
};

pub const SpawnOptions = struct {
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,
    defaults: Defaults = Defaults{},

    subscribed_style_sets: ?[]const u16 = null,
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

////////////////////////////////////////////////////////////////////////////////////////////// Reference for Testing

test {
    std.testing.refAllDeclsRecursive(WindowCache);
}
