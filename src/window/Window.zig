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
            .culling = opts.culling,
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

pub fn render(self: *@This(), is_active: bool, mall: *const RenderMall, _: ScreenView) void {

    ///////////////////////////// Profiling

    const render_zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
    defer render_zone.End();

    ///////////////////////////// Temporary Setup

    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const colorscheme = mall.colorscheme_store.getDefaultColorscheme() orelse unreachable;

    ///////////////////////////// Culling & Render

    const view = mall.icb.getViewFromCamera(mall.camera);
    const target_view = mall.icb.getViewFromCamera(mall.target_camera);

    if (self.isOutOfView(view)) return;

    var renderer = Renderer{
        .win = self,
        .view = view,
        .target_view = target_view,
        .default_font = default_font,
        .default_glyph = default_glyph,
        .render_callbacks = mall.rcb,
        .mall = mall,
    };
    if (renderer.shiftBoundedOffsetBy()) |change_by| {
        self.attr.bounds.offset.x += change_by[0];
        self.attr.bounds.offset.y += change_by[1];
        self.cursor_manager.setJustMovedToFalse();
    }
    renderer.initialize();
    renderer.render(colorscheme);

    if (is_active and !self.cursor_manager.just_moved) {
        const active_anchor = self.cursor_manager.mainCursor().activeAnchor(self.cursor_manager);

        if (renderer.potential_cursor_relocation_line) |relocation_line| {
            if (renderer.main_cursor_vertical_visibility != .in_view) {
                active_anchor.*.line = relocation_line;
            }
        }

        if (renderer.potential_cursor_relocation_col) |relocation_col| {
            if (renderer.main_cursor_horizontal_visibility != .in_view) {
                active_anchor.*.col = relocation_col;
            }
        }
    }

    if (renderer.shiftViewBy()) |shift_by| {
        mall.rcb.changeCameraPan(mall.target_camera, shift_by[0], shift_by[1]);
    }
    if (self.cursor_manager.just_moved and mall.icb.cameraTargetsEqual(mall.camera, mall.target_camera)) {
        self.cursor_manager.setJustMovedToFalse();
    }
}

fn isOutOfView(self: *@This(), view: ScreenView) bool {
    if (!self.attr.culling) return false;

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

////////////////////////////////////////////////////////////////////////////////////////////// Positioning

pub fn centerAt(self: *@This(), center_x: f32, center_y: f32) void {
    const x = center_x - (self.cached.width / 2);
    const y = center_y - (self.cached.height / 2);
    self.attr.pos = .{ .x = x, .y = y };
}

////////////////////////////////////////////////////////////////////////////////////////////// Renderer

const LastestRenderedCharInfo = ?struct { x: f32, width: f32, font_size: f32 };

const Renderer = struct {
    win: *Window,
    view: ScreenView,
    target_view: ScreenView,

    default_font: *const FontStore.Font,
    default_glyph: FontStore.Font.GlyphData,

    render_callbacks: RenderMall.RenderCallbacks,
    mall: *const RenderMall,

    linenr: usize = 0,
    colnr: usize = 0,

    char_y: f32 = 0,
    char_x: f32 = undefined,
    line_y: f32 = undefined,

    // selection related
    last_char_info: LastestRenderedCharInfo = null,
    selection_start_x: ?f32 = null,

    // cursor relocation related
    potential_cursor_relocation_line: ?usize = null,
    potential_cursor_relocation_col: ?usize = null,
    first_in_view_linenr: ?usize = null,
    main_cursor_vertical_visibility: enum { above, below, in_view } = .below,
    main_cursor_horizontal_visibility: enum { before, after, in_view } = .after,

    ///////////////////////////// initial values

    fn initialize(self: *@This()) void {
        self.char_x = self.calculateInitialLineX();
        self.line_y = self.calculateInitialLineY();
    }

    fn calculateInitialLineX(self: *@This()) f32 {
        if (self.win.attr.bounded) return self.win.attr.pos.x - self.win.attr.bounds.offset.x;
        return self.win.attr.pos.x;
    }

    fn calculateInitialLineY(self: *@This()) f32 {
        if (self.win.attr.bounded) return self.win.attr.pos.y - self.win.attr.bounds.offset.y;
        return self.win.attr.pos.y;
    }

    ///////////////////////////// updates

    fn nextLine(self: *@This()) void {
        self.char_x = self.calculateInitialLineX();
        self.line_y += self.lineHeight();
        self.last_char_info = null;
        self.selection_start_x = null;
    }

    fn updateCharY(self: *@This(), font: *const FontStore.Font, font_size: f32) void {
        const height_deficit = self.lineHeight() - font_size;
        const char_base = font.getAdaptedBaseLine(font_size);
        const char_shift = self.baseLine() - (height_deficit + char_base);
        self.char_y = self.line_y + height_deficit + char_shift;
    }

    ///////////////////////////// cursor relocation related

    // vertical

    fn updateMainCursorVerticalVisibilityReport(self: *@This(), linenr: usize) void {
        if (self.win.cursor_manager.mainCursor().activeAnchor(self.win.cursor_manager).line == linenr) {
            if (self.line_y < self.view.start.y) {
                self.main_cursor_vertical_visibility = .above;
                return;
            }
            if (self.line_y + self.lineHeight() > self.view.end.y) {
                self.main_cursor_vertical_visibility = .below;
                return;
            }
            self.main_cursor_vertical_visibility = .in_view;
            if (self.first_in_view_linenr == null) self.first_in_view_linenr = linenr;
        }
    }

    fn updatePotentialCursorRelocationLinenr(self: *@This(), linenr: usize) void {
        if (self.main_cursor_vertical_visibility == .above and
            self.potential_cursor_relocation_line != null) return;

        if (self.line_y > self.view.start.y and self.line_y + self.lineHeight() < self.view.end.y) {
            self.potential_cursor_relocation_line = linenr;
        }
    }

    // horizontal

    fn updateMainCursorHorizontalVisibilityReport(self: *@This(), char_x: f32, char_width: f32) void {
        const anchor = self.win.cursor_manager.mainCursor().activeAnchor(self.win.cursor_manager);
        if (anchor.line == self.linenr and anchor.col == self.colnr) {
            if (char_x + 1 < self.view.start.x) {
                self.main_cursor_horizontal_visibility = .before;
                return;
            }
            if (char_x + char_width > self.view.end.x) {
                self.main_cursor_horizontal_visibility = .after;
                return;
            }
            self.main_cursor_horizontal_visibility = .in_view;
        }
    }

    fn updatePotentialCursorRelocationColnr(self: *@This(), char_x: f32, char_width: f32) void {
        const anchor = self.win.cursor_manager.mainCursor().activeAnchor(self.win.cursor_manager);
        if (anchor.line == self.linenr) {
            if (self.first_in_view_linenr) |first_in_view_linenr| {
                if (self.linenr != first_in_view_linenr) return;
            }

            if (self.potential_cursor_relocation_line) |potential_cursor_relocation_line| {
                if (self.linenr != potential_cursor_relocation_line) return;
            }

            if (self.potential_cursor_relocation_col != null) {
                if (self.main_cursor_horizontal_visibility != .after) {
                    return;
                }
            }

            if (char_x > self.view.start.x and char_x + char_width < self.view.end.x) {
                self.potential_cursor_relocation_col = self.colnr;
            }
        }
    }

    ///////////////////////////// getters

    fn lineHeight(self: *@This()) f32 {
        return self.win.cached.line_info.items[self.linenr].height;
    }

    fn baseLine(self: *@This()) f32 {
        return self.win.cached.line_info.items[self.linenr].base_line;
    }

    fn boundStartX(self: *@This()) f32 {
        assert(self.win.attr.bounded);
        return self.win.attr.pos.x;
    }

    fn boundStartY(self: *@This()) f32 {
        assert(self.win.attr.bounded);
        return self.win.attr.pos.y;
    }

    fn boundEndX(self: *@This()) f32 {
        assert(self.win.attr.bounded);
        return self.win.attr.pos.x + self.win.attr.bounds.width;
    }

    fn boundEndY(self: *@This()) f32 {
        assert(self.win.attr.bounded);
        return self.win.attr.pos.y + self.win.attr.bounds.height;
    }

    ///////////////////////////// checkers

    fn lineYAboveView(self: *@This()) bool {
        if (!self.win.attr.culling) return false;

        const above_screen_view = self.line_y + self.lineHeight() < self.view.start.y;
        if (self.win.attr.bounded) {
            const above_bounds = self.line_y + self.lineHeight() < self.boundStartY();
            return above_bounds or above_screen_view;
        }
        return above_screen_view;
    }

    fn lineYBelowView(self: *@This()) bool {
        if (!self.win.attr.culling) return false;

        const below_screen_view = self.line_y > self.view.end.y;
        if (self.win.attr.bounded) {
            const below_bounds = self.line_y > (self.win.attr.pos.y + self.win.attr.bounds.height);
            return below_bounds or below_screen_view;
        }
        return below_screen_view;
    }

    fn lineStartPointOutOfView(self: *@This()) bool {
        if (!self.win.attr.culling) return false;

        const line_info = self.win.cached.line_info.items[self.linenr];

        const x_starts_out_of_view = self.char_x + line_info.width < self.view.start.x;
        const y_starts_out_of_view = self.line_y + line_info.height < self.view.start.y;
        const starts_out_of_view = x_starts_out_of_view or y_starts_out_of_view;

        if (!self.win.attr.bounded) return starts_out_of_view;

        const x_starts_out_of_bounds = self.char_x + line_info.width < self.boundStartX();
        const y_starts_out_of_bounds = self.line_y + line_info.height < self.boundStartY();
        const starts_out_of_bounds = x_starts_out_of_bounds or y_starts_out_of_bounds;
        return starts_out_of_bounds or starts_out_of_view;
    }

    fn charStartsAfterViewEnds(self: *@This()) bool {
        if (!self.win.attr.culling) return false;

        const char_start_after_view = self.char_x > self.view.end.x;
        if (!self.win.attr.bounded) return char_start_after_view;

        const char_start_after_bounds = self.char_x > self.boundEndX();
        return char_start_after_view or char_start_after_bounds;
    }

    fn charStartsBeforeBounds(self: *@This(), char_width: f32) bool {
        if (!self.win.attr.culling) return false;

        if (!self.win.attr.bounded) return false;
        return self.char_x + char_width < self.boundStartX();
    }

    fn charEndsBeforeViewStart(self: *@This(), char_width: f32) bool {
        if (!self.win.attr.culling) return false;

        return self.char_x + char_width < self.view.start.x;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// check if need to change view to main cursor anchor

    fn shiftViewBy(self: *@This()) ?struct { f32, f32 } {
        if (self.win.attr.bounded or !self.win.cursor_manager.just_moved) return null;

        var shift_view_x_by: f32 = 0;
        var shift_view_y_by: f32 = 0;

        const start_y, const end_y, const start_x, const end_x = self.getActiveAnchorCoordinates() catch return null;

        // Cursor relocation behavior can cause friction due to inadequate floating point calculations.
        // Use COCONUT_OIL to smooth things out.
        const COCONUT_OIL = 10;

        y_blk: {
            if (start_y < self.target_view.start.y) {
                shift_view_y_by = start_y - self.target_view.start.y - COCONUT_OIL;
                break :y_blk;
            }
            if (end_y > self.target_view.end.y) {
                shift_view_y_by = end_y - self.target_view.end.y + COCONUT_OIL;
            }
        }

        x_blk: {
            if (start_x < self.target_view.start.x) {
                shift_view_x_by = start_x - self.target_view.start.x - COCONUT_OIL;
                break :x_blk;
            }
            if (end_x > self.target_view.end.x) {
                shift_view_x_by = end_x - self.target_view.end.x + COCONUT_OIL;
            }
        }

        return .{ shift_view_x_by, shift_view_y_by };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// check if need to change bounded offset to main cursor anchor

    fn shiftBoundedOffsetBy(self: *@This()) ?struct { f32, f32 } {
        if (!self.win.attr.bounded or !self.win.cursor_manager.just_moved) return null;

        var change_offset_x_by: f32 = 0;
        var change_offset_y_by: f32 = 0;

        const start_y, const end_y, const start_x, const end_x = self.getActiveAnchorCoordinates() catch return null;

        y_blk: {
            if (start_y < self.boundStartY()) {
                change_offset_y_by = start_y - self.boundStartY();
                break :y_blk;
            }
            if (end_y > self.boundEndY()) {
                change_offset_y_by = end_y - self.boundEndY();
            }
        }

        x_blk: {
            if (start_x < self.boundStartX()) {
                change_offset_x_by = start_x - self.boundStartX();
                break :x_blk;
            }
            if (end_x > self.boundEndX()) {
                change_offset_x_by = end_x - self.boundEndX();
            }
        }

        return .{ change_offset_x_by, change_offset_y_by };
    }

    fn getActiveAnchorCoordinates(self: *@This()) !struct { f32, f32, f32, f32 } {
        const anchor = self.win.cursor_manager.mainCursor().activeAnchor(self.win.cursor_manager);

        var start_y: f32 = self.calculateInitialLineY();
        var start_x: f32 = self.calculateInitialLineX();
        var end_x: f32 = start_x;

        for (0..self.win.ws.buf.ropeman.getNumOfLines()) |linenr| {
            if (anchor.line == linenr) {
                var content_buf: [1024]u8 = undefined;
                const stored_captures: []WindowSource.StoredCapture = if (self.win.ws.ls != null)
                    self.win.ws.cap_list.items[anchor.line]
                else
                    &.{};

                var colnr: usize = 0;
                var iter = try WindowSource.LineIterator.init(self.win.ws, anchor.line, &content_buf);
                while (iter.next(stored_captures)) |r| {
                    defer colnr += 1;
                    start_x = end_x;

                    const font = getStyleFromStore(*const FontStore.Font, self.win, r, self.mall, RenderMall.getFont) orelse self.default_font;
                    const font_size = getStyleFromStore(f32, self.win, r, self.mall, RenderMall.getFontSize) orelse self.win.defaults.font_size;

                    const char_width = calculateGlyphWidth(font, font_size, r.code_point, self.default_glyph);
                    end_x += char_width;

                    if (anchor.col == colnr) break;
                }

                break;
            }

            start_y += self.win.cached.line_info.items[linenr].height;
        }
        const end_y = start_y + self.win.cached.line_info.items[anchor.line].height;

        return .{ start_y, end_y, start_x, end_x };
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// iterate through all the lines

    fn render(self: *@This(), colorscheme: *const ColorschemeStore.Colorscheme) void {
        var chars_rendered: i64 = 0;
        defer ztracy.PlotI("chars_rendered", chars_rendered);

        for (0..self.win.ws.buf.ropeman.getNumOfLines()) |linenr| {
            self.linenr = linenr;
            defer self.nextLine();

            // cursor relocation related
            self.updateMainCursorVerticalVisibilityReport(linenr);
            self.updatePotentialCursorRelocationLinenr(linenr);

            if (self.lineYBelowView()) return;
            if (self.lineYAboveView() or self.lineStartPointOutOfView()) continue;

            if (!self.iterateThroughCharsInLine(&chars_rendered, colorscheme)) continue;

            self.renderSelectionLinesBetweenStartAndEnd();
            if (self.renderCursorDotAtLineEnd()) continue;
            if (self.renderCursorOnEmptyLine()) continue;
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// iterate through characters in line

    fn iterateThroughCharsInLine(self: *@This(), chars_rendered: *i64, colorscheme: *const ColorschemeStore.Colorscheme) bool {
        self.colnr = 0;

        var content_buf: [1024]u8 = undefined;
        const stored_captures: []WindowSource.StoredCapture = if (self.win.ws.ls != null)
            self.win.ws.cap_list.items[self.linenr]
        else
            &.{};

        var iter = WindowSource.LineIterator.init(self.win.ws, self.linenr, &content_buf) catch return false;
        while (iter.next(stored_captures)) |r| {
            defer self.colnr += 1;

            switch (self.renderCharacter(r, colorscheme, chars_rendered)) {
                .should_break => break,
                .should_continue => continue,
                .keep_going => {},
            }

            self.renderInLineCursor();
            self.renderVisualRangeStartAndEnd();
        }

        return true;
    }

    const RenderCharacterResult = enum { should_break, should_continue, keep_going };

    fn renderCharacter(self: *@This(), r: WindowSource.LineIterator.Result, colorscheme: *const ColorschemeStore.Colorscheme, chars_rendered: *i64) RenderCharacterResult {
        const font = getStyleFromStore(*const FontStore.Font, self.win, r, self.mall, RenderMall.getFont) orelse self.default_font;
        const font_size = getStyleFromStore(f32, self.win, r, self.mall, RenderMall.getFontSize) orelse self.win.defaults.font_size;

        const char_width = calculateGlyphWidth(font, font_size, r.code_point, self.default_glyph);
        defer self.char_x += char_width;

        // cursor relocation related
        self.updateMainCursorHorizontalVisibilityReport(self.char_x, char_width);
        self.updatePotentialCursorRelocationColnr(self.char_x, char_width);

        if (self.charStartsAfterViewEnds()) return .should_break;
        if (self.charStartsBeforeBounds(char_width)) return .should_continue;
        if (self.charEndsBeforeViewStart(char_width)) return .should_continue;

        assert(self.lineHeight() >= font_size);
        const color = self.win.getCharColor(r, colorscheme);
        self.updateCharY(font, font_size);

        self.render_callbacks.drawCodePoint(font, r.code_point, self.char_x, self.char_y, font_size, color);
        chars_rendered.* += 1;

        self.last_char_info = .{ .x = self.char_x, .width = char_width, .font_size = font_size };
        return .keep_going;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// render cursor & visual range

    fn updateLastCharInfo(self: *@This(), font_size: f32, char_width: f32) void {
        self.last_char_info = .{ .x = self.char_x, .width = char_width, .font_size = font_size };
    }

    fn renderInLineCursor(self: *@This()) void {
        const last_char_info = self.last_char_info orelse return;
        for (self.win.cursor_manager.cursors.values()) |*cursor| {
            const anchor = cursor.activeAnchor(self.win.cursor_manager);
            if (anchor.line != self.linenr or anchor.col != self.colnr) continue;
            self.render_callbacks.drawRectangle(
                last_char_info.x,
                self.char_y,
                last_char_info.width,
                last_char_info.font_size,
                self.win.defaults.color,
            );
        }
    }

    fn renderVisualRangeStartAndEnd(self: *@This()) void {
        if (self.win.cursor_manager.cursor_mode != .range) return;
        const last_char_info = self.last_char_info orelse return;

        const line_width = self.win.cached.line_info.items[self.linenr].width;
        for (self.win.cursor_manager.cursors.values()) |*cursor| {
            if (cursor.start.line == self.linenr and cursor.start.col == self.colnr) {
                if (self.selection_start_x == null) self.selection_start_x = last_char_info.x;

                if (cursor.end.line == self.linenr) continue;

                // selection starts on this line but ends elsewhere
                const width = line_width - (self.char_x - self.win.attr.pos.x);
                self.render_callbacks.drawRectangle(last_char_info.x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                continue;
            }

            if (cursor.end.line == self.linenr and cursor.end.col == self.colnr) {

                // selection starts and ends on this line
                if (self.selection_start_x) |start_x| {
                    const width = last_char_info.x + last_char_info.width - start_x;
                    self.render_callbacks.drawRectangle(start_x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                    continue;
                }

                // selection started elsewhere and ends here
                const width = last_char_info.x + last_char_info.width - self.win.attr.pos.x;
                self.render_callbacks.drawRectangle(self.win.attr.pos.x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                continue;
            }
        }
    }

    fn renderSelectionLinesBetweenStartAndEnd(self: *@This()) void {
        if (self.win.cursor_manager.cursor_mode != .range) return;
        const line_width = self.win.cached.line_info.items[self.linenr].width;

        for (self.win.cursor_manager.cursors.values()) |*cursor| {
            if (cursor.start.line < self.linenr and cursor.end.line > self.linenr) {
                self.render_callbacks.drawRectangle(
                    self.win.attr.pos.x,
                    self.line_y,
                    line_width,
                    self.lineHeight(),
                    self.win.defaults.selection_color,
                );
            }
        }
    }

    fn renderCursorDotAtLineEnd(self: *@This()) bool {
        if (self.last_char_info) |info| {
            for (self.win.cursor_manager.cursors.values()) |*cursor| {
                const anchor = cursor.activeAnchor(self.win.cursor_manager);
                if (anchor.line != self.linenr or anchor.col != self.colnr) continue;

                // cursor relocation related
                self.updateMainCursorHorizontalVisibilityReport(info.x + info.width, info.width);
                self.updatePotentialCursorRelocationColnr(info.x + info.width, info.width);

                self.render_callbacks.drawRectangle(
                    info.x + info.width,
                    self.line_y,
                    info.width,
                    info.font_size,
                    self.win.defaults.color,
                );
            }
            return true;
        }
        return false;
    }

    fn renderCursorOnEmptyLine(self: *@This()) bool {
        if (self.colnr > 0) return false;

        for (self.win.cursor_manager.cursors.values()) |*cursor| {
            const anchor = cursor.activeAnchor(self.win.cursor_manager);
            if (anchor.line != self.linenr) continue;

            const char_width = calculateGlyphWidth(self.default_font, self.win.defaults.font_size, ' ', self.default_glyph);

            // cursor relocation related
            self.updateMainCursorHorizontalVisibilityReport(self.char_x + char_width, char_width);
            self.updatePotentialCursorRelocationColnr(self.char_x + char_width, char_width);

            self.render_callbacks.drawRectangle(self.char_x, self.line_y, char_width, self.lineHeight(), self.win.defaults.color);
        }

        return true;
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn processEditResult(self: *@This(), replace_infos: []const WindowSource.ReplaceInfo, mall: *const RenderMall) !void {
    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;
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
    self.cached.updateWidthHeight();
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

    fn updateWidthHeight(self: *@This()) void {
        self.width = 0;
        self.height = 0;
        for (self.line_info.items) |info| {
            self.width = @max(self.width, info.width);
            self.height += info.height;
        }
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

pub fn calculateGlyphWidth(font: *const Font, font_size: f32, code_point: u21, default_glyph: GlyphData) f32 {
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
    culling: bool = true,
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,
    defaults: Defaults = Defaults{},

    subscribed_style_sets: ?[]const u16 = null,
};

const Attributes = struct {
    culling: bool = true,
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
