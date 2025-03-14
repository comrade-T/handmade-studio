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

const _qtree = @import("QuadTree");
const QuadTree = _qtree.QuadTree(Window);
const Rect = RenderMall.Rect;

const CursorManager = @import("CursorManager");
const WindowCache = @import("Window/WindowCache.zig");
const Renderer = @import("Window/Renderer.zig");

pub const UNSET_WIN_ID = std.math.maxInt(i128);
pub const ID = i128;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
cached: WindowCache = undefined,
defaults: Defaults,
subscribed_style_sets: SubscribedStyleSets,
cursor_manager: *CursorManager,
closed: bool = false,

id: ID = UNSET_WIN_ID,

pub fn create(
    a: Allocator,
    may_qtree: ?*QuadTree,
    ws: *WindowSource,
    opts: SpawnOptions,
    mall: *const RenderMall,
) !*Window {
    var self = try a.create(@This());

    self.* = .{
        .a = a,
        .ws = ws,
        .attr = .{
            .culling = opts.culling,

            .pos = opts.pos,
            .absolute = opts.absolute,
            .target_pos = opts.pos,

            .bordered = opts.bordered,
            .padding = if (opts.padding) |p| p else Attributes.Padding{},
            .bounds = if (opts.bounds) |b| b else Attributes.Bounds{},
            .bounded = if (opts.bounds) |_| true else false,
        },
        .defaults = opts.defaults,
        .subscribed_style_sets = SubscribedStyleSets{},
        .cursor_manager = try CursorManager.create(self.a),
    };

    if (opts.subscribed_style_sets) |slice| try self.subscribed_style_sets.appendSlice(self.a, slice);
    if (opts.id) |id| self.id = id;

    // this must be called last
    self.cached = try WindowCache.init(self.a, self, mall);

    if (opts.limit) |limit| {
        self.attr.limit = limit;
        self.cursor_manager.setLimit(limit.start_line, limit.end_line);
    }

    if (may_qtree) |qtree| try qtree.insert(a, self, self.getRect());

    return self;
}

pub fn destroy(self: *@This(), may_qtree_a: ?Allocator, may_qtree: ?*QuadTree) void {
    if (may_qtree) |qtree| assert(qtree.remove(may_qtree_a.?, self, self.getRect()).removed);
    self.cached.deinit(self.a);
    self.subscribed_style_sets.deinit(self.a);
    self.cursor_manager.destroy();
    self.a.destroy(self);
}

pub fn open(self: *@This()) void {
    self.closed = false;
}

pub fn close(self: *@This()) void {
    self.closed = true;
}

// pub fn subscribeToStyleSet(self: *@This(), styleset_id: u16) !void {
//     try self.subscribed_style_sets.append(self.a, styleset_id);
// }

pub fn centerCameraAt(self: *const @This(), screen_rect: Rect, mall: *const RenderMall) void {
    const win_center_x = self.getX() + self.getWidth() / 2;
    const win_center_y = self.getY() + self.getHeight() / 2;

    const screen_center_x = screen_rect.x + screen_rect.width / 2;
    const screen_center_y = screen_rect.y + screen_rect.height / 2;

    const x_by = win_center_x - screen_center_x;
    const y_by = win_center_y - screen_center_y;

    mall.rcb.changeCameraPan(mall.target_camera, x_by, y_by);
}

////////////////////////////////////////////////////////////////////////////////////////////// Setters

pub fn centerAt(self: *@This(), a: Allocator, qtree: *QuadTree, center_x: f32, center_y: f32) !void {
    const x = center_x - (self.cached.width / 2);
    const y = center_y - (self.cached.height / 2);
    try self.setTargetPosition(a, qtree, x, y);
}

pub fn moveBy(self: *@This(), a: Allocator, qtree: *QuadTree, umap: *UpdatingWindowsMap, x: f32, y: f32) !void {
    self.removeFromQuadTree(a, qtree);

    self.attr.target_pos.x += x;
    self.attr.target_pos.y += y;
    try umap.put(a, self, {});

    try self.insertToQuadTree(a, qtree);
}

pub fn setPositionInstantly(self: *@This(), a: Allocator, qtree: *QuadTree, x: f32, y: f32) !void {
    self.removeFromQuadTree(a, qtree);

    self.attr.pos.x = x;
    self.attr.pos.y = y;
    self.attr.target_pos.x = x;
    self.attr.target_pos.y = y;

    try self.insertToQuadTree(a, qtree);
}

pub fn setTargetPosition(self: *@This(), a: Allocator, qtree: *QuadTree, x: f32, y: f32) !void {
    self.removeFromQuadTree(a, qtree);

    self.attr.target_pos.x = x;
    self.attr.target_pos.y = y;

    try self.insertToQuadTree(a, qtree);
}

pub fn setID(self: *@This(), id: ID) void {
    self.id = id;
}

pub fn toggleBorder(self: *@This()) void {
    self.attr.bordered = !self.attr.bordered;
}

pub fn changeBoundSizeBy(self: *@This(), width_by: f32, height_by: f32) void {
    if (!self.attr.bounded) return;
    self.attr.bounds.width += width_by;
    self.attr.bounds.height += height_by;
}

pub fn toggleBounds(self: *@This()) void {
    self.attr.bounded = !self.attr.bounded;
}

pub fn changePaddingBy(self: *@This(), a: Allocator, qtree: *QuadTree, x_by: f32, y_by: f32) !void {
    self.removeFromQuadTree(a, qtree);

    self.attr.padding.left += x_by;
    self.attr.padding.right += x_by;
    self.attr.padding.top += y_by;
    self.attr.padding.bottom += y_by;

    try self.insertToQuadTree(a, qtree);
}

////////////////////////////////////////////////////////////////////////////////////////////// Getters

pub fn getX(self: *const @This()) f32 {
    return self.attr.pos.x;
}

pub fn getY(self: *const @This()) f32 {
    return self.attr.pos.y;
}

pub fn getContentWidth(self: *const @This()) f32 {
    return self.cached.width;
}

pub fn getContentHeight(self: *const @This()) f32 {
    return self.cached.height;
}

pub fn getWidth(self: *const @This()) f32 {
    if (self.attr.bounded) return self.attr.bounds.width;
    return self.getContentWidth() + self.attr.padding.left + self.attr.padding.right;
}

pub fn getHeight(self: *const @This()) f32 {
    if (self.attr.bounded) return self.attr.bounds.height;
    return self.getContentHeight() + self.attr.padding.top + self.attr.padding.bottom;
}

pub fn getRect(self: *const @This()) Rect {
    return .{
        .x = self.getX(),
        .y = self.getY(),
        .width = self.getWidth(),
        .height = self.getHeight(),
    };
}

////////////////////////////////////////////////////////////////////////////////////////////// Update

pub const UpdatingWindowsMap = std.AutoArrayHashMapUnmanaged(*Window, void);

pub fn update(self: *@This(), a: Allocator, qtree: *QuadTree, umap: *UpdatingWindowsMap) !void {
    if (self.attr.pos.equals(self.attr.target_pos)) {
        assert(umap.swapRemove(self));
        return;
    }

    self.removeFromQuadTree(a, qtree);
    self.attr.pos.update(self.attr.target_pos);
    try self.insertToQuadTree(a, qtree);
}

fn removeFromQuadTree(self: *@This(), a: Allocator, qtree: *QuadTree) void {
    const qtree_remove_result = qtree.remove(a, self, self.getRect());
    assert(qtree_remove_result.removed);
}

fn insertToQuadTree(self: *@This(), a: Allocator, qtree: *QuadTree) !void {
    try qtree.insert(a, self, self.getRect());
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This(), is_active: bool, mall: *RenderMall, may_view: ?RenderMall.ScreenView) void {

    ///////////////////////////// Profiling

    const render_zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
    defer render_zone.End();

    ///////////////////////////// Sanity Checks

    assert(!self.closed);
    assert(!(self.attr.limit != null and self.attr.bounded));

    ///////////////////////////// Temporary Setup

    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;

    const colorscheme = mall.colorscheme_store.getDefaultColorscheme() orelse unreachable;

    ///////////////////////////// Culling & Render

    const view = if (self.attr.absolute)
        mall.getAbsoluteScreenView()
    else
        may_view orelse mall.icb.getViewFromCamera(mall.camera);

    const target_view = if (self.attr.absolute)
        mall.getAbsoluteScreenView()
    else
        mall.icb.getViewFromCamera(mall.target_camera);

    if (mall.camera_just_moved) {
        mall.camera_just_moved = false;
        if (self.cursor_manager.just_moved) self.cursor_manager.setJustMovedToFalse();
    }

    if (self.isOutOfView(view)) return;

    var renderer = Renderer{
        .win = self,
        .win_is_active = is_active,
        .view = view,
        .target_view = target_view,
        .default_font = default_font,
        .default_glyph = default_glyph,
        .rcb = mall.rcb,
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

    // if (renderer.shiftViewBy()) |shift_by| {
    //     mall.rcb.changeCameraPan(mall.target_camera, shift_by[0], shift_by[1]);
    // }
    if (self.cursor_manager.just_moved and mall.icb.cameraTargetsEqual(mall.camera, mall.target_camera)) {
        self.cursor_manager.setJustMovedToFalse();
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn processEditResult(
    self: *@This(),
    a: ?Allocator,
    may_qtree: ?*QuadTree,
    replace_infos: []const WindowSource.ReplaceInfo,
    mall: *const RenderMall,
) !void {
    if (may_qtree) |qtree| self.removeFromQuadTree(a.?, qtree);

    const default_font = mall.font_store.getDefaultFont() orelse unreachable;
    const default_glyph = default_font.glyph_map.get('?') orelse unreachable;
    for (replace_infos) |ri| {
        try self.cached.updateCacheLines(self, ri, mall, default_font, default_glyph);

        // limit related
        if (self.attr.limit) |limit| {
            self.attr.limit = Window.getUpdatedLimits(limit, ri);
            self.cursor_manager.setLimit(self.attr.limit.?.start_line, self.attr.limit.?.end_line);
        }
    }

    if (may_qtree) |qtree| try self.insertToQuadTree(a.?, qtree);
}

fn getUpdatedLimits(curr_: ?CursorManager.Limit, ri: WindowSource.ReplaceInfo) ?CursorManager.Limit {
    const curr = curr_ orelse return null;
    const line_number_deficit = @as(i64, @intCast(ri.end_line + 1)) - @as(i64, @intCast(ri.start_line)) - @as(i64, @intCast(ri.replace_len));

    const totally_above = ri.start_line < curr.start_line and ri.end_line < curr.end_line;
    if (totally_above) {
        return CursorManager.Limit{
            .start_line = @intCast(@as(i64, @intCast(curr.start_line)) + line_number_deficit),
            .end_line = @intCast(@as(i64, @intCast(curr.end_line)) + line_number_deficit),
        };
    }

    if (ri.start_line >= curr.start_line and ri.end_line >= curr.end_line) {
        return CursorManager.Limit{
            .start_line = curr.start_line,
            .end_line = @intCast(@as(i64, @intCast(curr.end_line)) + line_number_deficit),
        };
    }

    return curr;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn isOutOfView(self: *@This(), view: ScreenView) bool {
    if (!self.attr.culling) return false;

    if (self.attr.pos.x > view.end.x) return true;
    if (self.attr.pos.y > view.end.y) return true;

    if (self.attr.pos.x + self.cached.width < view.start.x) return true;
    if (self.attr.pos.y + self.cached.height < view.start.y) return true;

    return false;
}

pub fn getCharColor(self: *@This(), r: WindowSource.LineIterator.Result, colorscheme: *const ColorschemeStore.Colorscheme) u32 {
    var color = self.defaults.color;

    for (r.ids) |id| {
        const group_name = self.ws.ls.?.highlight_queries.values()[id.query_id].query.getCaptureNameForId(id.capture_id);
        if (colorscheme.get(group_name)) |c| {
            color = c;
            break;
        }
    }

    // var i: usize = r.ids.len;
    // while (i > 0) {
    //     i -= 1;
    //     const id = r.ids[i];
    //     const group_name = self.ws.ls.?.queries.values()[id.query_id].query.getCaptureNameForId(id.capture_id);
    //     if (colorscheme.get(group_name)) |c| {
    //         color = c;
    //         break;
    //     }
    // }

    return color;
}

pub fn getStyleFromStore(T: type, win: *const Window, r: Window.WindowSource.LineIterator.Result, mall: *const RenderMall, cb: anytype) ?T {
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

////////////////////////////////////////////////////////////////////////////////////////////// Insertsect

pub fn horizontalIntersect(self: *const Window, other: *const Window) bool {
    return !(self.attr.pos.x > other.attr.pos.x + other.cached.width or
        self.attr.pos.x + self.cached.width < other.attr.pos.x);
}

pub fn verticalIntersect(self: *const Window, other: *const Window) bool {
    return !(self.attr.pos.y > other.attr.pos.y + other.cached.height or
        self.attr.pos.y + self.cached.height < other.attr.pos.y);
}

pub fn intersects(self: *const Window, other: *const Window) bool {
    return horizontalIntersect(self, other) and verticalIntersect(self, other);
}

////////////////////////////////////////////////////////////////////////////////////////////// Session

fn produceSpawnOptions(self: *@This()) SpawnOptions {
    return SpawnOptions{
        .culling = self.attr.culling,
        .pos = self.attr.target_pos,
        .bounds = if (self.attr.bounded) self.attr.bounds else null,
        .padding = self.attr.padding,
        .limit = self.attr.limit,
        // .defaults = self.defaults,
        .subscribed_style_sets = self.subscribed_style_sets.items,
        .id = if (self.id != UNSET_WIN_ID) self.id else null,
        .bordered = self.attr.bordered,
    };
}

pub fn produceWritableState(self: *@This(), may_string_id: ?ID) !WritableWindowState {
    assert(!self.closed);
    return WritableWindowState{
        .opts = self.produceSpawnOptions(),
        .source = switch (self.ws.from) {
            .file => .{ .file = self.ws.path },
            .string => .{ .string = may_string_id.? },
        },
    };
}

pub const WritableWindowState = struct {
    opts: Window.SpawnOptions,
    source: union(enum) {
        file: []const u8,
        string: ID,
    },
};

////////////////////////////////////////////////////////////////////////////////////////////// Types

const SubscribedStyleSets = std.ArrayListUnmanaged(u16);

const Defaults = struct {
    font_size: f32 = 40,
    color: u32 = 0xF5F5F5F5,
    main_cursor_when_active: u32 = 0xF5F5F5F5,
    main_cursor_when_inactive: u32 = 0xF5F5F500,
    selection_color: u32 = 0xF5F5F533,
    border_color: u32 = 0xF5F5F5F5,
};

pub const SpawnOptions = struct {
    culling: bool = true,
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,
    limit: ?CursorManager.Limit = null,
    defaults: Defaults = Defaults{},

    bordered: bool = false,

    absolute: bool = false,

    subscribed_style_sets: ?[]const u16 = null,

    id: ?ID = null,
};

pub const Attributes = struct {
    culling: bool = true,

    pos: Position,
    absolute: bool = false,
    target_pos: Position = .{},

    bounded: bool,
    bounds: Bounds,

    bordered: bool,
    padding: Padding,

    limit: ?CursorManager.Limit = null,

    const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
        lerp_time: f32 = 0.2,

        const epsilon = 0.01;

        fn equals(self: @This(), other: @This()) bool {
            return @abs(self.x - other.x) < epsilon and @abs(self.y - other.y) < epsilon;
        }

        fn update(self: *@This(), target: Position) void {
            self.x = RenderMall.lerp(self.x, target.x, self.lerp_time);
            self.y = RenderMall.lerp(self.y, target.y, self.lerp_time);
        }
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

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    try eq(208, @sizeOf(Window));
}
