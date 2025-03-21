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

const WindowManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangHub = @import("LangSuite").LangHub;
pub const RenderMall = @import("RenderMall");
pub const Rect = RenderMall.Rect;
const AnchorPicker = @import("AnchorPicker");
pub const WindowSource = @import("WindowSource");
pub const Window = @import("Window");

const ip_ = @import("input_processor");
pub const MappingCouncil = ip_.MappingCouncil;
pub const Callback = ip_.Callback;

const ConnectionManager = @import("WindowManager/ConnectionManager.zig");
const HistoryManager = @import("WindowManager/HistoryManager.zig");
const WindowPicker = @import("WindowManager/WindowPicker.zig");
const vim_related = @import("WindowManager/vim_related.zig");
const layout_related = @import("WindowManager/layout_related.zig");
const _qtree = @import("QuadTree");
const QuadTree = _qtree.QuadTree(Window);
const NotificationLine = @import("NotificationLine");

////////////////////////////////////////////////////////////////////////////////////////////// mapKeys

pub fn mapKeys(self: *@This(), ap: *const AnchorPicker, council: *MappingCouncil) !void {
    try self.connman.mapKeys(council);
    try vim_related.mapKeys(self, council);
    try layout_related.mapKeys(self, council);

    try self.mapSpawnBlankWindowKeymaps(ap, council);

    try self.mapUndoRedoKeymaps(council);
    try council.map(NORMAL, &.{ .left_control, .q }, .{ .f = closeActiveWindow, .ctx = self });

    try council.map(NORMAL, &.{ .left_control, .left_shift, .left_alt, .q }, .{ .f = closeAllWindows, .ctx = self });
    try council.map(NORMAL, &.{ .left_control, .left_alt, .left_shift, .q }, .{ .f = closeAllWindows, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_control, .left_alt, .q }, .{ .f = closeAllWindows, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_alt, .left_control, .q }, .{ .f = closeAllWindows, .ctx = self });
    try council.map(NORMAL, &.{ .left_alt, .left_control, .left_shift, .q }, .{ .f = closeAllWindows, .ctx = self });
    try council.map(NORMAL, &.{ .left_alt, .left_shift, .left_control, .q }, .{ .f = closeAllWindows, .ctx = self });

    try WindowPicker.mapKeys(self, council);
}

const NORMAL = "normal";

fn mapSpawnBlankWindowKeymaps(wm: *@This(), ap: *const AnchorPicker, c: *MappingCouncil) !void {
    const Cb = struct {
        direction: WindowManager.WindowRelativeDirection,
        wm: *WindowManager,
        mall: *const RenderMall,
        ap: *const AnchorPicker,

        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

            if (self.wm.active_window == null) {
                const x, const y = self.wm.mall.icb.getScreenToWorld2D(
                    self.mall.camera,
                    self.ap.target_anchor.x,
                    self.ap.target_anchor.y,
                );

                try self.wm.spawnWindow(.string, "", .{ .pos = .{ .x = x, .y = y } }, true, true);
                return;
            }

            try self.wm.spawnNewWindowRelativeToActiveWindow(.string, "", .{}, self.direction, false);
        }

        pub fn init(
            allocator: std.mem.Allocator,
            wm_: *WindowManager,
            mall_: *const RenderMall,
            ap_: *const AnchorPicker,
            direction: WindowManager.WindowRelativeDirection,
        ) !Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .wm = wm_, .mall = mall_, .ap = ap_ };
            return Callback{ .f = @This().f, .ctx = self };
        }
    };

    const a = c.arena.allocator();
    try c.map(NORMAL, &.{ .left_control, .n }, try Cb.init(a, wm, wm.mall, ap, .bottom));
    try c.map(NORMAL, &.{ .left_control, .left_shift, .n }, try Cb.init(a, wm, wm.mall, ap, .right));
    try c.map(NORMAL, &.{ .left_shift, .left_control, .n }, try Cb.init(a, wm, wm.mall, ap, .right));
}

fn mapUndoRedoKeymaps(self: *@This(), council: *MappingCouncil) !void {
    try council.map(NORMAL, &.{ .left_control, .z }, .{ .f = undo, .ctx = self });
    try council.map(NORMAL, &.{ .left_control, .left_shift, .z }, .{ .f = redo, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_control, .z }, .{ .f = redo, .ctx = self });

    try council.map(NORMAL, &.{ .left_control, .left_alt, .z }, .{ .f = batchUndo, .ctx = self });
    try council.map(NORMAL, &.{ .left_alt, .left_control, .z }, .{ .f = batchUndo, .ctx = self });

    try council.map(NORMAL, &.{ .left_control, .left_shift, .left_alt, .z }, .{ .f = batchRedo, .ctx = self });
    try council.map(NORMAL, &.{ .left_control, .left_alt, .left_shift, .z }, .{ .f = batchRedo, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_control, .left_alt, .z }, .{ .f = batchRedo, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_alt, .left_control, .z }, .{ .f = batchRedo, .ctx = self });
    try council.map(NORMAL, &.{ .left_alt, .left_control, .left_shift, .z }, .{ .f = batchRedo, .ctx = self });
    try council.map(NORMAL, &.{ .left_alt, .left_shift, .left_control, .z }, .{ .f = batchRedo, .ctx = self });
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,
nl: *NotificationLine,

active_window: ?*Window = null,

handlers: WindowSourceHandlerMap = WindowSourceHandlerMap{},
last_win_id: i128 = Window.UNSET_WIN_ID,

fmap: FilePathToHandlerMap = FilePathToHandlerMap{},
wmap: WindowToHandlerMap = WindowToHandlerMap{},

connman: ConnectionManager,
hm: HistoryManager,

qtree: *QuadTree,
updating_windows_map: Window.UpdatingWindowsMap = .{},
visible_windows: WindowList,

window_picker: WindowPicker,

pub fn create(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall, nl: *NotificationLine) !*WindowManager {
    const QUADTREE_WIDTH = 2_000_000;

    const self = try a.create(@This());
    self.* = WindowManager{
        .a = a,
        .lang_hub = lang_hub,
        .mall = style_store,
        .nl = nl,
        .connman = ConnectionManager{ .wm = self },
        .hm = HistoryManager{ .a = a, .capacity = 1024 },

        .qtree = try QuadTree.create(a, .{
            .x = -QUADTREE_WIDTH / 2,
            .y = -QUADTREE_WIDTH / 2,
            .width = QUADTREE_WIDTH,
            .height = QUADTREE_WIDTH,
        }, 0),
        .visible_windows = std.ArrayList(*Window).init(a),

        .window_picker = WindowPicker{ .wm = self },
    };
    return self;
}

pub fn updateAndRender(self: *@This()) !void {
    const windows_to_be_updated = self.updating_windows_map.keys();
    var i: usize = windows_to_be_updated.len;
    while (i > 0) {
        i -= 1;
        try windows_to_be_updated[i].update(self.a, self.qtree, &self.updating_windows_map);
    }

    try self.render();
}

pub fn render(self: *@This()) !void {
    const screen_rect = self.mall.getScreenRect();

    // NOTE: put a `defer` statement here and `WindowPicker.moveTo()` won't work
    // due to keyboard events get resolved before `render()` is called.
    self.visible_windows.clearRetainingCapacity();

    try self.getAllVisibleWindowsOnScreen(screen_rect, &self.visible_windows);

    for (self.visible_windows.items) |window| {
        const is_active = if (self.active_window) |active_window| active_window == window else false;
        window.render(is_active, self.mall, null);
    }

    // std.debug.print("#wins: {d} | visible on screen: {d} | #windows in tree: {d}\n", .{
    //     self.wmap.keys().len,
    //     self.visible_windows.items.len,
    //     self.qtree.getNumberOfItems(),
    // });
    self.connman.render();

    self.window_picker.render(screen_rect);
}

pub fn destroy(self: *@This()) void {
    self.connman.deinit();

    for (self.handlers.keys()) |handler| handler.destroy(self);
    self.handlers.deinit(self.a);

    self.fmap.deinit(self.a);
    self.wmap.deinit(self.a);

    self.hm.deinit();

    self.qtree.destroy(self.a);
    self.visible_windows.deinit();
    self.updating_windows_map.deinit(self.a);

    self.a.destroy(self);
}

pub fn setActiveWindow(self: *@This(), win: ?*Window) void {
    self.active_window = win;
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowSourceHandler

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerMap = std.AutoArrayHashMapUnmanaged(*WindowSourceHandler, void);
const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowMap,

    const WindowMap = std.AutoArrayHashMapUnmanaged(*Window, void);

    fn create(wm: *WindowManager, from: WindowSource.InitFrom, source: []const u8, lang_hub: *LangHub) !*WindowSourceHandler {
        const self = try wm.a.create(@This());
        self.* = WindowSourceHandler{
            .source = try WindowSource.create(wm.a, from, source, lang_hub),
            .windows = WindowMap{},
        };
        return self;
    }

    fn destroy(self: *@This(), wm: *WindowManager) void {
        for (self.windows.keys()) |window| window.destroy(wm.a, wm.qtree);
        self.windows.deinit(wm.a);
        self.source.destroy();
        wm.a.destroy(self);
    }

    fn spawnWindow(self: *@This(), wm: *WindowManager, opts: Window.SpawnOptions) !*Window {
        const window = try Window.create(wm.a, wm.qtree, self.source, opts, wm.mall);
        try self.windows.put(window.a, window, {});

        set_win_id: { // set id for window
            if (opts.id) |id| {
                window.setID(id);
                break :set_win_id;
            }

            var id = std.time.nanoTimestamp();
            while (true) {
                if (id != wm.last_win_id) break;
                id = std.time.nanoTimestamp();
            }
            wm.last_win_id = id;
            window.setID(id);
        }

        assert(window.id != Window.UNSET_WIN_ID);
        try wm.connman.registerWindow(window);

        // quick & hacky solution for limiting the cursor to the window limit
        window.cursor_manager.moveUp(1, &self.source.buf.ropeman);

        return window;
    }

    fn cleanUp(self: *@This(), win: *Window, wm: *WindowManager) void {
        wm.connman.removeAllConnectionsOfWindow(win);

        const removed_from_windows = self.windows.swapRemove(win);
        assert(removed_from_windows);

        const removed_from_wmap = wm.wmap.swapRemove(win);
        assert(removed_from_wmap);

        win.destroy(wm.a, wm.qtree);

        if (self.windows.values().len == 0) {
            if (self.source.from == .file) {
                const removed_from_fmap = wm.fmap.swapRemove(self.source.path);
                assert(removed_from_fmap);
            }

            const removed_from_handlers = wm.handlers.swapRemove(self);
            assert(removed_from_handlers);
            self.destroy(wm);
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Get Info

pub const WindowList = std.ArrayList(*Window);

pub fn getAllVisibleWindowsOnScreen(self: *const @This(), screen_rect: Rect, list: *WindowList) !void {
    try self.qtree.query(screen_rect, list, isWindowOnScreen);
}

fn isWindowOnScreen(query_rect: Rect, win: *const Window) bool {
    return !win.closed and query_rect.overlaps(win.getRect());
}

////////////////////////////////////////////////////////////////////////////////////////////// Make closest window active

pub fn findClosestWindowToDirection(self: *const @This(), curr: *const Window, direction: WindowRelativeDirection) struct { f32, ?*Window } {
    var distance: f32 = std.math.floatMax(f32);
    var candidate: ?*Window = null;

    const curr_edge_stat = getWindowEdgeStat(curr);

    for (self.wmap.keys()) |win| {
        if (win == curr) continue;
        if (win.closed) continue;

        const cond = switch (direction) {
            .left => win.getX() < curr.getX(),
            .right => win.getX() > curr.getX(),
            .top => win.getY() < curr.getY(),
            .bottom => win.getY() > curr.getY(),
        };
        if (!cond) continue;

        const edge = findEdge(direction, win, curr);
        const d = calculateTotalDistance(direction, getWindowEdgeStat(win), curr_edge_stat, edge);
        if (d >= distance) continue;

        distance = d;
        candidate = win;
    }

    return .{ distance, candidate };
}

const WindowEdgeStat = struct { left: f32, right: f32, mid_x: f32, top: f32, bottom: f32, mid_y: f32 };
fn getWindowEdgeStat(win: *const Window) WindowEdgeStat {
    return WindowEdgeStat{
        .left = win.getX(),
        .right = win.getX() + win.getWidth(),
        .mid_x = win.getX() + win.getWidth() / 2,
        .top = win.getY(),
        .bottom = win.getY() + win.getHeight(),
        .mid_y = win.getY() + win.getHeight() / 2,
    };
}

const WindowEdge = enum { left, right, top, bottom };
fn findEdge(direction: WindowRelativeDirection, to: *const Window, from: *const Window) WindowEdge {
    return switch (direction) {
        .left => if (to.horizontalIntersect(from)) .left else .right,
        .right => if (to.horizontalIntersect(from)) .right else .left,
        .top => if (to.verticalIntersect(from)) .top else .bottom,
        .bottom => if (to.verticalIntersect(from)) .bottom else .top,
    };
}

fn calculateTotalDistance(direction: WindowRelativeDirection, to: WindowEdgeStat, from: WindowEdgeStat, edge: WindowEdge) f32 {
    const md = calculateMainAxisDistance(direction, to, from, edge);
    const sd = calculateSubAxisDistance(direction, to, from);
    return md + sd;
}

fn calculateMainAxisDistance(direction: WindowRelativeDirection, to: WindowEdgeStat, from: WindowEdgeStat, edge: WindowEdge) f32 {
    return switch (direction) {
        .left => switch (edge) {
            .left => @abs(to.left - from.left),
            .right => @abs(to.right - from.left),
            else => unreachable,
        },
        .right => switch (edge) {
            .left => @abs(to.left - from.right),
            .right => @abs(to.right - from.right),
            else => unreachable,
        },
        .top => switch (edge) {
            .top => @abs(to.top - from.top),
            .bottom => @abs(to.bottom - from.top),
            else => unreachable,
        },
        .bottom => switch (edge) {
            .top => @abs(to.top - from.bottom),
            .bottom => @abs(to.bottom - from.bottom),
            else => unreachable,
        },
    };
}

fn calculateSubAxisDistance(direction: WindowRelativeDirection, to: WindowEdgeStat, from: WindowEdgeStat) f32 {
    return switch (direction) {
        .left, .right => @abs(to.mid_y - from.mid_y),
        .top, .bottom => @abs(to.mid_x - from.mid_x),
    };
}

////////////////////////////////////////////////////////////////////////////////////////////// Spawn Window

pub fn spawnWindowFromHandler(self: *@This(), handler: *WindowSourceHandler, opts: Window.SpawnOptions, make_active: bool) !void {
    const window = try handler.spawnWindow(self, opts);
    try self.wmap.put(self.a, window, handler);
    if (make_active or self.active_window == null) self.setActiveWindow(window);
}

pub fn spawnWindow(
    self: *@This(),
    from: WindowSource.InitFrom,
    source: []const u8,
    opts: Window.SpawnOptions,
    make_active: bool,
    add_to_history: bool,
) !void {

    // if file path exists in fmap
    if (from == .file) {
        if (self.fmap.get(source)) |handler| {
            const window = try handler.spawnWindow(self, opts);
            try self.wmap.put(self.a, window, handler);
            if (add_to_history) try self.addWindowToSpawnHistory(window);
            if (make_active or self.active_window == null) self.setActiveWindow(window);
            return;
        }
    }

    // spawn from scratch
    var handler = try WindowSourceHandler.create(self, from, source, self.lang_hub);
    try self.handlers.put(self.a, handler, {});

    const window = try handler.spawnWindow(self, opts);
    if (add_to_history) try self.addWindowToSpawnHistory(window);
    try self.wmap.put(self.a, window, handler);

    if (from == .file) try self.fmap.put(self.a, handler.source.path, handler);

    if (make_active or self.active_window == null) self.setActiveWindow(window);
}

////////////////////////////////////////////////////////////////////////////////////////////// History

fn addWindowToSpawnHistory(self: *@This(), win: *Window) !void {
    self.cleanUpWindowsAfterAppendingToHistory(
        self.a,
        try self.hm.addSpawnEvent(self.a, win),
    );
}

fn addWindowToCloseHistory(self: *@This(), win: *Window) !void {
    self.cleanUpWindowsAfterAppendingToHistory(
        self.a,
        try self.hm.addCloseEvent(self.a, win),
    );
}

pub fn cleanUpWindowsAfterAppendingToHistory(self: *@This(), a: Allocator, windows_to_clean_up: []*Window) void {
    defer a.free(windows_to_clean_up);
    for (windows_to_clean_up) |win| {
        if (!win.closed) continue;
        var handler = self.wmap.get(win) orelse continue;
        handler.cleanUp(win, self);
    }
}

/////////////////////////////

pub fn undo(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.hm.undo()) |event| try self.handleUndoEvent(event);
}

fn handleUndoEvent(self: *@This(), event: HistoryManager.Event) !void {
    switch (event) {
        .spawn => |win| try self.closeWindow(win, false),
        .close => |win| self.openWindowAndMakeActive(win),
        .toggle_border => |win| win.toggleBorder(),
        .change_padding => |info| try info.win.changePaddingBy(self.a, self.qtree, -info.x_by, -info.y_by),
        .move => |info| try info.win.moveBy(self.a, self.qtree, &self.updating_windows_map, -info.x_by, -info.y_by),
    }
}

pub fn batchUndo(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const curr, const target = self.hm.batchUndo();

    var i: i64 = curr;
    while (i > target and i >= 0) {
        defer i -= 1;
        assert(i >= 0);
        const event = self.hm.events.get(@intCast(i));
        try self.handleUndoEvent(event);
    }
}

pub fn redo(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.hm.redo()) |event| try self.handleRedoEvent(event);
}

fn handleRedoEvent(self: *@This(), event: HistoryManager.Event) !void {
    switch (event) {
        .spawn => |win| self.openWindowAndMakeActive(win),
        .close => |win| try self.closeWindow(win, false),
        .toggle_border => |win| win.toggleBorder(),
        .change_padding => |info| try info.win.changePaddingBy(self.a, self.qtree, info.x_by, info.y_by),
        .move => |info| try info.win.moveBy(self.a, self.qtree, &self.updating_windows_map, info.x_by, info.y_by),
    }
}

pub fn batchRedo(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const curr, const target = self.hm.batchRedo();

    var i: i64 = curr;
    while (i <= target and i >= 0) {
        defer i += 1;
        assert(i < self.hm.events.len);
        const event = self.hm.events.get(@intCast(i));
        try self.handleRedoEvent(event);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Close Window

pub fn closeActiveWindow(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const active_window = self.active_window orelse return;
    try self.closeWindow(active_window, true);
}

pub fn closeAllWindows(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const windows = self.wmap.keys();

    var i: usize = windows.len;
    while (i > 0) {
        i -= 1;
        try self.closeWindow(windows[i], true);
    }
}

fn findClosestWindow(self: *@This(), from: *const Window) ?*Window {
    var distance: f32 = std.math.floatMax(f32);
    var candidate: ?*Window = null;

    const top_d, const top_c = self.findClosestWindowToDirection(from, .top);
    const bottom_d, const bottom_c = self.findClosestWindowToDirection(from, .bottom);
    const left_d, const left_c = self.findClosestWindowToDirection(from, .left);
    const right_d, const right_c = self.findClosestWindowToDirection(from, .right);

    const distances = [4]f32{ top_d, bottom_d, left_d, right_d };
    const candidates = [4]?*Window{ top_c, bottom_c, left_c, right_c };

    for (distances, 0..) |d, i| {
        if (d < distance) {
            distance = d;
            candidate = candidates[i];
        }
    }

    return candidate;
}

fn closeWindow(self: *@This(), win: *Window, add_to_history: bool) !void {
    const new_active_window = self.findClosestWindow(win);
    win.close();
    if (add_to_history) try self.addWindowToCloseHistory(win);
    self.setActiveWindow(new_active_window);
}

fn openWindowAndMakeActive(self: *@This(), win: *Window) void {
    win.open();
    self.setActiveWindow(win);
}

////////////////////////////////////////////////////////////////////////////////////////////// Auto Layout

pub const WindowRelativeDirection = enum { left, right, top, bottom };

pub fn spawnNewWindowRelativeToActiveWindow(
    self: *@This(),
    from: WindowSource.InitFrom,
    source: []const u8,
    opts: Window.SpawnOptions,
    direction: WindowRelativeDirection,
    move: bool,
) !void {
    const prev = self.active_window orelse return;

    try self.spawnWindow(from, source, opts, true, true);
    const new = self.active_window orelse unreachable;

    var new_x: f32 = new.getX();
    var new_y: f32 = new.getY();
    switch (direction) {
        .right => {
            new_x = prev.getX() + prev.getWidth();
            new_y = prev.getY();
        },
        .left => {
            new_x = prev.getX() - new.getWidth();
            new_y = prev.getY();
        },
        .bottom => {
            new_x = prev.getX();
            new_y = prev.getY() + prev.getHeight();
        },
        .top => {
            new_x = prev.getX();
            new_y = prev.getY() - new.getHeight();
        },
    }
    try new.setPositionInstantly(self.a, self.qtree, new_x, new_y);

    if (!move) return;
    for (self.wmap.keys()) |window| {
        if (window == prev or window == new) continue;
        switch (direction) {
            .right => {
                if (window.getX() > prev.getX() and window.verticalIntersect(prev)) {
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, new.getWidth(), 0);
                }
            },
            .left => {
                if (window.getX() < prev.getX() and
                    window.verticalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, -new.getWidth(), 0);
            },
            .bottom => {
                if (window.getY() > prev.getY() and
                    window.horizontalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, 0, new.getHeight());
            },
            .top => {
                if (window.getY() < prev.getY() and
                    window.horizontalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, 0, -new.getHeight());
            },
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Session

const StringSource = struct {
    id: i128,
    contents: []const u8,
};

const Session = struct {
    cameraInfo: ?RenderMall.CameraInfo = null,
    string_sources: []const StringSource,
    connections: []*const ConnectionManager.Connection,
    windows: []const Window.WritableWindowState,
};

pub fn loadSession(self: *@This(), session_path: []const u8) !void {

    ///////////////////////////// read file & parse

    const file = std.fs.cwd().openFile(session_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("catched err: {any} --> returning.\n", .{err});
        return;
    };
    defer file.close();
    const stat = try file.stat();

    const buf = try self.a.alloc(u8, stat.size);
    defer self.a.free(buf);
    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    const parsed = try std.json.parseFromSlice(Session, self.a, buf, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    ///////////////////////////// call setCamera() if canvas is empty

    if (parsed.value.cameraInfo) |camera_info| blk: {
        var has_visible_windows = false;
        for (self.wmap.keys()) |window| {
            if (!window.closed) {
                has_visible_windows = true;
                break;
            }
        }
        if (has_visible_windows) break :blk;
        self.mall.rcb.setCamera(self.mall.camera, camera_info);
        self.mall.rcb.setCamera(self.mall.target_camera, camera_info);
    }

    ///////////////////////////// create handlers & spawn windows

    // If we load a session from a file, then load the same session again,
    // those carry the same winids, both for windows and connections.
    // Without adjusting `increment_winid_by`, we'll run into winid collisions,
    // which causes `connman.notifyTrackers()` to misbehave & cause leaks.

    var increment_winid_by: Window.ID = 0;
    const current_nano_timestamp = std.time.nanoTimestamp();
    for (parsed.value.windows) |window_state| {
        const winid = window_state.opts.id orelse continue;
        if (self.connman.tracker_map.contains(winid)) {
            assert(current_nano_timestamp > winid);
            increment_winid_by = current_nano_timestamp - winid;
            break;
        }
    }

    var strid_to_handler_map = std.AutoArrayHashMap(i128, *WindowSourceHandler).init(self.a);
    defer strid_to_handler_map.deinit();

    for (parsed.value.string_sources) |str_source| {
        const handler = try WindowSourceHandler.create(self, .string, str_source.contents, self.lang_hub);
        try self.handlers.put(self.a, handler, {});
        try strid_to_handler_map.put(str_source.id, handler);
    }

    for (parsed.value.windows) |state| {
        var adjusted_opts = state.opts;
        if (adjusted_opts.id == null) continue;
        adjusted_opts.id.? += increment_winid_by;

        switch (state.source) {
            .file => |path| try self.spawnWindow(.file, path, adjusted_opts, true, false),
            .string => |string_id| {
                const handler = strid_to_handler_map.get(string_id) orelse continue;
                try self.spawnWindowFromHandler(handler, adjusted_opts, true);
            },
        }
    }

    for (parsed.value.connections) |conn| {
        var adjusted_connection = conn.*;
        adjusted_connection.start.win_id += increment_winid_by;
        adjusted_connection.end.win_id += increment_winid_by;

        assert(self.connman.tracker_map.contains(adjusted_connection.start.win_id));
        assert(self.connman.tracker_map.contains(adjusted_connection.end.win_id));
        try self.connman.notifyTrackers(adjusted_connection);
    }
}

pub fn saveSession(self: *@This(), path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var string_source_list = std.ArrayList(StringSource).init(self.a);
    defer string_source_list.deinit();

    var window_to_id_map = std.AutoArrayHashMap(*Window, i128).init(self.a);
    defer window_to_id_map.deinit();

    ///////////////////////////// handle string sources

    var last_id: i128 = std.math.maxInt(i128);
    for (self.handlers.keys()) |handler| {
        if (handler.source.from == .file) continue;

        // only save handlers with visible windows
        var ignore_this_handler = true;
        for (handler.windows.keys()) |window| {
            if (!window.closed) {
                ignore_this_handler = false;
                break;
            }
        }
        if (ignore_this_handler) continue;

        var id = std.time.nanoTimestamp();
        while (true) {
            if (id != last_id) break;
            id = std.time.nanoTimestamp();
        }
        last_id = id;

        const contents = try handler.source.buf.ropeman.toString(arena.allocator(), .lf);
        try string_source_list.append(StringSource{
            .id = id,
            .contents = contents,
        });

        for (handler.windows.keys()) |window| {
            try window_to_id_map.put(window, id);
        }
    }

    ///////////////////////////// handle windows

    var window_state_list = std.ArrayList(Window.WritableWindowState).init(self.a);
    defer window_state_list.deinit();

    for (self.wmap.keys()) |window| {
        if (window.closed) continue;
        const string_id: ?i128 = window_to_id_map.get(window) orelse null;
        const data = try window.produceWritableState(string_id);
        try window_state_list.append(data);
    }

    ///////////////////////////// handle connections

    var connections = std.ArrayListUnmanaged(*const ConnectionManager.Connection){};
    defer connections.deinit(self.a);

    for (self.connman.connections.keys()) |conn| {
        if (!conn.isVisible(self)) continue;
        try connections.append(self.a, conn);
    }

    /////////////////////////////

    const session = Session{
        .cameraInfo = self.mall.icb.getCameraInfo(self.mall.camera),
        .windows = window_state_list.items,
        .string_sources = string_source_list.items,
        .connections = connections.items,
    };

    const str = try std.json.stringifyAlloc(arena.allocator(), session, .{
        .whitespace = .indent_4,
    });

    try writeToFile(str, path);

    const msg = try std.fmt.allocPrint(self.a, "Session written to file '{s}' successfully", .{path});
    defer self.a.free(msg);
    try self.nl.setMessage(msg);
}

fn writeToFile(str: []const u8, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(str);
}
