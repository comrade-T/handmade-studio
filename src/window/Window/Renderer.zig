const ztracy = @import("ztracy");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Window = @import("../Window.zig");
const WindowSource = Window.WindowSource;
const RenderMall = Window.RenderMall;
const FontStore = RenderMall.FontStore;
const ScreenView = RenderMall.ScreenView;
const ColorschemeStore = RenderMall.ColorschemeStore;

//////////////////////////////////////////////////////////////////////////////////////////////

const LastestRenderedCharInfo = ?struct { x: f32, width: f32, font_size: f32 };

win: *Window,
view: ScreenView,
target_view: ScreenView,
win_is_active: bool,
win_is_selected: bool,

default_font: *const FontStore.Font,
default_glyph: FontStore.Font.GlyphData,

rcb: RenderMall.RenderCallbacks,
mall: *const RenderMall,

linenr: usize = 0,
colnr: usize = 0,

char_y: f32 = 0,
char_x: f32 = undefined,
line_y: f32 = undefined,

cursor_animator: ?*Window.CursorAnimator,

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

pub fn initialize(self: *@This()) void {
    self.char_x = self.calculateInitialLineX();
    self.line_y = self.calculateInitialLineY();
}

fn calculateInitialLineX(self: *@This()) f32 {
    if (self.win.attr.bounded) return self.win.attr.pos.x - self.win.attr.bounds.offset.x + self.win.attr.padding.left;
    return self.win.attr.pos.x + self.win.attr.padding.left;
}

fn calculateInitialLineY(self: *@This()) f32 {
    if (self.win.attr.bounded) return self.win.attr.pos.y - self.win.attr.bounds.offset.y + self.win.attr.padding.top;
    return self.win.attr.pos.y + self.win.attr.padding.top;
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
    return self.win.attr.pos.x + self.win.attr.padding.left;
}

fn boundStartY(self: *@This()) f32 {
    assert(self.win.attr.bounded);
    return self.win.attr.pos.y + self.win.attr.padding.top;
}

fn boundEndX(self: *@This()) f32 {
    assert(self.win.attr.bounded);
    return self.win.attr.pos.x + self.win.attr.bounds.width -
        self.win.attr.padding.right;
}

fn boundEndY(self: *@This()) f32 {
    assert(self.win.attr.bounded);
    return self.win.attr.pos.y + self.win.attr.bounds.height -
        self.win.attr.padding.bottom;
}

///////////////////////////// checkers

fn withinLimit(self: *@This()) bool {
    const limit = self.win.attr.limit orelse return true;
    return self.linenr >= limit.start_line and self.linenr <= limit.end_line;
}

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

pub fn shiftViewBy(self: *@This()) ?struct { f32, f32 } {
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

pub fn shiftBoundedOffsetBy(self: *@This()) ?struct { f32, f32 } {
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

                const font = Window.getStyleFromStore(*const FontStore.Font, self.win, r, self.mall, RenderMall.getFont) orelse self.default_font;
                const font_size = Window.getStyleFromStore(f32, self.win, r, self.mall, RenderMall.getFontSize) orelse self.win.defaults.font_size;

                const char_width = RenderMall.calculateGlyphWidth(font, font_size, r.code_point, self.default_glyph);
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

pub fn render(self: *@This(), colorscheme: *const ColorschemeStore.Colorscheme) void {
    var chars_rendered: i64 = 0;
    defer ztracy.PlotI("chars_rendered", chars_rendered);

    ///////////////////////////// Render Background Image

    if (self.win.background_image) |img| self.renderBackgroundImage(img);

    ///////////////////////////// Render Border

    const mall = self.mall;
    const win = self.win;

    defer if (self.win_is_selected or self.win.attr.bordered) { // temporary solution for selectAllDescendants() MVP
        const THICKNESS = 2;
        mall.rcb.drawRectangleLines(
            win.getX(),
            win.getY(),
            win.getWidth(),
            win.getHeight(),
            THICKNESS,
            win.defaults.border_color,
        );
    };

    ///////////////////////////// Scissoring

    if (win.attr.bounded) {
        const screen_x, const screen_y = mall.icb.getWorldToScreen2D(mall.camera, win.getX(), win.getY());

        const camera_zoom = mall.icb.getCameraZoom(mall.camera);

        const screen_width = (win.attr.bounds.width - win.attr.padding.right) * camera_zoom;
        const screen_height = (win.attr.bounds.height - win.attr.padding.bottom) * camera_zoom;

        mall.rcb.beginScissorMode(screen_x, screen_y, screen_width, screen_height);
    }

    defer if (win.attr.bounded) {
        mall.rcb.endScissorMode();
    };

    ///////////////////////////// Text Rendering

    for (0..win.ws.buf.ropeman.getNumOfLines()) |linenr| {
        self.linenr = linenr;

        if (self.win.attr.limit) |limit| {
            if (linenr < limit.start_line) continue;
            if (linenr > limit.end_line) break;
        }

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
    const font = Window.getStyleFromStore(*const FontStore.Font, self.win, r, self.mall, RenderMall.getFont) orelse self.default_font;
    const font_size = Window.getStyleFromStore(f32, self.win, r, self.mall, RenderMall.getFontSize) orelse self.win.defaults.font_size;

    const char_width = RenderMall.calculateGlyphWidth(font, font_size, r.code_point, self.default_glyph);
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

    self.rcb.drawCodePoint(font, r.code_point, self.char_x, self.char_y, font_size, color);
    chars_rendered.* += 1;

    self.last_char_info = .{ .x = self.char_x, .width = char_width, .font_size = font_size };
    return .keep_going;
}

////////////////////////////////////////////////////////////////////////////////////////////// render cursor & visual range

fn getCursorColor(self: *@This()) u32 {
    return if (self.win_is_active or self.cursor_animator != null)
        self.win.defaults.main_cursor_when_active
    else
        self.win.defaults.main_cursor_when_inactive;
}

fn updateLastCharInfo(self: *@This(), font_size: f32, char_width: f32) void {
    self.last_char_info = .{ .x = self.char_x, .width = char_width, .font_size = font_size };
}

fn renderInLineCursor(self: *@This()) void {
    const last_char_info = self.last_char_info orelse return;
    for (self.win.cursor_manager.cursors.values()) |*cursor| {
        const anchor = cursor.activeAnchor(self.win.cursor_manager);
        if (anchor.line != self.linenr or anchor.col != self.colnr) continue;
        self.renderCursor(last_char_info.x, last_char_info.width);
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
            self.rcb.drawRectangle(last_char_info.x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
            continue;
        }

        if (cursor.end.line == self.linenr and cursor.end.col == self.colnr) {

            // selection starts and ends on this line
            if (self.selection_start_x) |start_x| {
                const width = last_char_info.x + last_char_info.width - start_x;
                self.rcb.drawRectangle(start_x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
                continue;
            }

            // selection started elsewhere and ends here
            const width = last_char_info.x + last_char_info.width - self.win.attr.pos.x;
            self.rcb.drawRectangle(self.win.attr.pos.x, self.line_y, width, self.lineHeight(), self.win.defaults.selection_color);
            continue;
        }
    }
}

fn renderSelectionLinesBetweenStartAndEnd(self: *@This()) void {
    if (self.win.cursor_manager.cursor_mode != .range) return;
    const line_width = self.win.cached.line_info.items[self.linenr].width;

    for (self.win.cursor_manager.cursors.values()) |*cursor| {
        if (cursor.start.line < self.linenr and cursor.end.line > self.linenr) {
            self.rcb.drawRectangle(
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

            self.renderCursor(info.x + info.width, info.width);
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

        const char_width = RenderMall.calculateGlyphWidth(self.default_font, self.win.defaults.font_size, ' ', self.default_glyph);

        // cursor relocation related
        self.updateMainCursorHorizontalVisibilityReport(self.char_x + char_width, char_width);
        self.updatePotentialCursorRelocationColnr(self.char_x + char_width, char_width);

        self.renderCursor(self.char_x, char_width);
    }

    return true;
}

fn renderCursor(self: *@This(), x: f32, char_width: f32) void {
    const width = if (self.cursor_animator) |ca| blk: {
        ca.update();
        break :blk char_width * ca.progress;
    } else char_width;
    self.rcb.drawRectangle(x, self.line_y, width, self.lineHeight(), self.getCursorColor());
}

////////////////////////////////////////////////////////////////////////////////////////////// Image

fn renderBackgroundImage(self: *@This(), img: *const RenderMall.Image) void {
    // TODO:

    img.draw(self.mall, self.win.getX(), self.win.getY(), 0, 1);
}
