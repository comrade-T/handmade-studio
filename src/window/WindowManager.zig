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

pub const LangHub = @import("LangSuite").LangHub;
pub const RenderMall = @import("RenderMall");
pub const Rect = RenderMall.Rect;
const AnchorPicker = @import("AnchorPicker");
pub const WindowSource = @import("WindowSource");
pub const Window = @import("Window");

const ip_ = @import("input_processor");
pub const MappingCouncil = ip_.MappingCouncil;
pub const Callback = ip_.Callback;

pub const ConnectionManager = @import("WindowManager/ConnectionManager.zig");
const HistoryManager = @import("WindowManager/HistoryManager.zig");
const Windows = HistoryManager.Windows;
const WindowSwitchHistoryManager = @import("WindowManager/WindowSwitchHistoryManager.zig");
pub const WindowPicker = @import("WindowManager/WindowPicker.zig");
const _qtree = @import("QuadTree");
const QuadTree = _qtree.QuadTree(Window);

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,

active_window: ?*Window = null,

handlers: WindowSourceHandlerMap = WindowSourceHandlerMap{},
last_win_id: i128 = Window.UNSET_WIN_ID,

fmap: FilePathToHandlerMap = FilePathToHandlerMap{},
wmap: WindowToHandlerMap = WindowToHandlerMap{},

connman: ConnectionManager,
hm: HistoryManager,
wshm: WindowSwitchHistoryManager,

qtree: *QuadTree,
updating_windows_map: Window.UpdatingWindowsMap = .{},
visible_windows: WindowList,

window_picker_normal: WindowPicker,
selection_window_picker: WindowPicker,

selection: Selection,

pub fn create(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall) !*WindowManager {
    const QUADTREE_WIDTH = 2_000_000;

    const self = try a.create(@This());
    self.* = WindowManager{
        .a = a,
        .lang_hub = lang_hub,
        .mall = style_store,
        .connman = try ConnectionManager.init(a, self),
        .hm = HistoryManager{ .a = a, .capacity = 1024 },
        .wshm = WindowSwitchHistoryManager{ .wm = self },

        .qtree = try QuadTree.create(a, .{
            .x = -QUADTREE_WIDTH / 2,
            .y = -QUADTREE_WIDTH / 2,
            .width = QUADTREE_WIDTH,
            .height = QUADTREE_WIDTH,
        }, 0),
        .visible_windows = std.ArrayList(*Window).init(a),

        .selection = try Selection.init(a),

        .window_picker_normal = WindowPicker{ .wm = self, .callback = .{ .f = setActiveWindowPickerCallback, .ctx = self } },
        .selection_window_picker = WindowPicker{ .wm = self, .callback = .{ .f = toggleWindowFromSelection, .ctx = self } },
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
    const screen_rect = self.mall.getScreenRect(null);

    // NOTE: put a `defer` statement here and `WindowPicker.moveTo()` won't work
    // due to keyboard events get resolved before `render()` is called.
    self.visible_windows.clearRetainingCapacity();

    try self.getAllVisibleWindowsOnScreen(screen_rect, &self.visible_windows);

    for (self.visible_windows.items) |window| {
        const is_active = if (self.active_window) |active_window| active_window == window else false;
        const is_selected = if (self.selection.wmap.get(window)) |_| true else false;
        window.render(is_active, is_selected, self.mall, null);
    }

    // std.debug.print("#wins: {d} | visible on screen: {d} | #windows in tree: {d}\n", .{
    //     self.wmap.keys().len,
    //     self.visible_windows.items.len,
    //     self.qtree.getNumberOfItems(),
    // });
    self.connman.render();

    self.window_picker_normal.render();
    self.selection_window_picker.render();
}

pub fn destroy(self: *@This()) void {
    self.connman.deinit();

    for (self.handlers.keys()) |handler| handler.destroy(self);
    self.handlers.deinit(self.a);

    self.fmap.deinit(self.a);
    self.wmap.deinit(self.a);

    self.qtree.destroy(self.a);
    self.visible_windows.deinit();
    self.updating_windows_map.deinit(self.a);

    self.selection.deinit();

    self.hm.deinit();
    self.wshm.deinit();

    self.a.destroy(self);
}

pub fn setActiveWindow(self: *@This(), win: ?*Window, add_to_history: bool) void {
    if (add_to_history) self.wshm.addNewEvent(.{ .from = self.active_window, .to = win }) catch {};
    self.active_window = win;
}

fn setActiveWindowPickerCallback(ctx: *anyopaque, window: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.setActiveWindow(window, true);
    window.centerCameraAt(self.mall);
}

pub fn undoWindowSwitch(self: *@This()) !void {
    const new_win = self.wshm.undo() orelse return;
    self.setActiveWindow(new_win, false);
    new_win.centerCameraAt(self.mall);
}

pub fn redoWindowSwitch(self: *@This()) !void {
    const new_win = self.wshm.redo() orelse return;
    self.setActiveWindow(new_win, false);
    new_win.centerCameraAt(self.mall);
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowSourceHandler

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerMap = std.AutoArrayHashMapUnmanaged(*WindowSourceHandler, void);
pub const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowMap,

    const WindowMap = std.AutoArrayHashMapUnmanaged(*Window, void);

    pub fn create(wm: *WindowManager, from: WindowSource.InitFrom, source: []const u8, lang_hub: *LangHub) !*WindowSourceHandler {
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
        wm.wshm.purgeWindow(win);
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
    if (make_active or self.active_window == null) self.setActiveWindow(window, true);
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
            if (add_to_history) try self.addWindowToSpawnHistory(&.{window});
            if (make_active or self.active_window == null) self.setActiveWindow(window, true);
            return;
        }
    }

    // spawn from scratch
    var handler = try WindowSourceHandler.create(self, from, source, self.lang_hub);
    try self.handlers.put(self.a, handler, {});

    const window = try handler.spawnWindow(self, opts);
    if (add_to_history) try self.addWindowToSpawnHistory(&.{window});
    try self.wmap.put(self.a, window, handler);

    if (from == .file) try self.fmap.put(self.a, handler.source.path, handler);

    if (make_active or self.active_window == null) self.setActiveWindow(window, true);
}

////////////////////////////////////////////////////////////////////////////////////////////// History

fn addWindowToSpawnHistory(self: *@This(), windows: Windows) !void {
    self.cleanUpAfterAppendingToHistory(
        self.a,
        try self.hm.addSpawnEvent(self.a, windows),
    );
}

fn addWindowToCloseHistory(self: *@This(), windows: Windows) !void {
    self.cleanUpAfterAppendingToHistory(
        self.a,
        try self.hm.addCloseEvent(self.a, windows),
    );
}

pub fn cleanUpAfterAppendingToHistory(self: *@This(), a: Allocator, append_result: HistoryManager.AddNewEventResult) void {
    defer a.free(append_result.connections_to_cleanup);
    for (append_result.connections_to_cleanup) |conn| {
        self.connman.cleanUpConnectionAfterAppendingToHistory(conn);
    }

    defer a.free(append_result.windows_to_cleanup);
    for (append_result.windows_to_cleanup) |win| {
        if (!win.closed) continue;
        var handler = self.wmap.get(win) orelse continue;
        handler.cleanUp(win, self);
    }
}

/////////////////////////////

pub fn undo(self: *@This()) !void {
    if (self.hm.undo()) |event| try self.handleUndoEvent(event);
}

fn handleUndoEvent(self: *@This(), event: HistoryManager.Event) !void {
    switch (event) {
        .spawn => |windows| try self.closeWindows(windows, false),
        .close => |windows| self.openWindowAndMakeActive(windows),
        .toggle_border => |windows| for (windows) |win| win.toggleBorder(),

        .change_padding => |info| for (info.windows) |win|
            try win.changePaddingBy(self.a, self.qtree, -info.x_by, -info.y_by),

        .move => |info| for (info.windows) |win|
            try win.moveBy(self.a, self.qtree, &self.updating_windows_map, -info.x_by, -info.y_by),

        .add_connection => |conn| conn.hide(),
        .hide_connection => |conn| conn.show(&self.connman),
        .swap_selected_connection_points => |conn| conn.swapPoints(&self.connman),
        .set_connection_arrowhead => |info| info.conn.arrowhead_index = info.prev,
    }
}

pub fn batchUndo(self: *@This()) !void {
    const curr, const target = self.hm.batchUndo();

    var i: i64 = curr;
    while (i > target and i >= 0) {
        defer i -= 1;
        assert(i >= 0);
        const event = self.hm.events.get(@intCast(i));
        try self.handleUndoEvent(event);
    }
}

pub fn redo(self: *@This()) !void {
    if (self.hm.redo()) |event| try self.handleRedoEvent(event);
}

fn handleRedoEvent(self: *@This(), event: HistoryManager.Event) !void {
    switch (event) {
        .spawn => |windows| self.openWindowAndMakeActive(windows),
        .close => |windows| try self.closeWindows(windows, false),
        .toggle_border => |windows| for (windows) |win| win.toggleBorder(),

        .change_padding => |info| for (info.windows) |win|
            try win.changePaddingBy(self.a, self.qtree, info.x_by, info.y_by),

        .move => |info| for (info.windows) |win|
            try win.moveBy(self.a, self.qtree, &self.updating_windows_map, info.x_by, info.y_by),

        /////////////////////////////

        .add_connection => |conn| conn.show(&self.connman),
        .hide_connection => |conn| conn.hide(),
        .swap_selected_connection_points => |conn| conn.swapPoints(&self.connman),
        .set_connection_arrowhead => |info| info.conn.arrowhead_index = info.next,
    }
}

pub fn batchRedo(self: *@This()) !void {
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

pub fn getActiveWindows(self: *@This()) ?Windows {
    if (!self.selection.isEmpty()) return self.selection.windows();
    if (self.active_window == null) return null;
    return (&self.active_window.?)[0..1];
}

pub fn closeActiveWindow(self: *@This()) !void {
    const windows = self.getActiveWindows() orelse return;
    try self.closeWindows(windows, true);
}

pub fn closeAllWindows(self: *@This()) !void {
    try self.closeWindows(self.wmap.keys(), true);
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

fn closeWindows(self: *@This(), windows: Windows, add_to_history: bool) !void {
    if (windows.len == 0) {
        assert(false);
        return;
    }

    const new_active_window = self.findClosestWindow(windows[0]);

    var i: usize = windows.len;
    while (i > 0) {
        i -= 1;
        windows[i].close();
    }

    if (add_to_history) try self.addWindowToCloseHistory(windows);

    self.setActiveWindow(new_active_window, false);
}

fn openWindowAndMakeActive(self: *@This(), windows: Windows) void {
    if (windows.len == 0) {
        assert(false);
        return;
    }
    for (windows) |win| win.open();
    self.setActiveWindow(windows[0], false);
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

////////////////////////////////////////////////////////////////////////////////////////////// Selection

const Selection = struct {
    wmap: WindowMap,

    const WindowMap = std.AutoArrayHashMap(*Window, void);

    fn init(a: Allocator) !Selection {
        return Selection{ .wmap = WindowMap.init(a) };
    }

    fn deinit(self: *@This()) void {
        self.wmap.deinit();
    }

    fn windows(self: *const @This()) []const *Window {
        return self.wmap.keys();
    }

    fn isEmpty(self: *const @This()) bool {
        return self.windows().len == 0;
    }

    fn addWindow(self: *@This(), win: *Window) !void {
        try self.wmap.put(win, {});
    }

    fn toggleWindow(self: *@This(), win: *Window) !void {
        if (self.wmap.contains(win)) {
            assert(self.wmap.orderedRemove(win));
            return;
        }
        try self.wmap.put(win, {});
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Flicker Strike

pub fn getFirstVisibleIncomingWindow(self: *@This()) ?*Window {
    const active_window = self.active_window orelse return null;
    const tracker = self.connman.tracker_map.get(active_window.id) orelse return null;
    if (tracker.incoming.count() == 0) return null;

    var may_visible_index: ?usize = null;
    const keys = tracker.incoming.keys();
    for (0..tracker.incoming.count()) |i| {
        if (keys[i].isVisible(self)) {
            may_visible_index = i;
            break;
        }
    }

    const visible_index = may_visible_index orelse return null;
    const conn = keys[visible_index];
    const from_tracker = self.connman.tracker_map.get(conn.start.win_id) orelse return null;
    return from_tracker.win;
}

const AlignConnectionKind = ConnectionManager.AlignConnectionKind;
pub fn alignWindows(self: *@This(), mover: *Window, target: *Window, kind: AlignConnectionKind) !void {
    const active_window = self.active_window orelse return;
    var targets: []const *Window = &.{mover};
    if (mover == active_window) targets = self.getActiveWindows() orelse return;

    switch (kind) {
        .vertical => {
            const y_by = mover.getVerticalAlignDistance(target);
            for (targets) |win| try win.moveBy(self.a, self.qtree, &self.updating_windows_map, 0, y_by);
            self.cleanUpAfterAppendingToHistory(self.a, try self.hm.addMoveEvent(self.a, targets, 0, y_by));
        },
        .horizontal => {
            const x_by = mover.getHorizontalAlignDistance(target);
            for (targets) |win| try win.moveBy(self.a, self.qtree, &self.updating_windows_map, x_by, 0);
            self.cleanUpAfterAppendingToHistory(self.a, try self.hm.addMoveEvent(self.a, targets, x_by, 0));
        },
    }
}

/////////////////////////////

pub fn selectActiveWindow(self: *@This()) !void {
    if (!self.selection.isEmpty()) return;
    const active_window = self.active_window orelse return;
    try self.selection.addWindow(active_window);
}

pub fn selectAllDescendants(self: *@This()) !void {
    if (!self.selection.isEmpty()) return;
    const active_window = self.active_window orelse return;

    var list = std.ArrayList(*Window).init(self.a);
    defer list.deinit();

    try list.append(active_window);

    var i: usize = 0;
    while (i < list.items.len) {
        defer i += 1;
        const window = list.items[i];
        const tracker = self.connman.tracker_map.get(window.id) orelse continue;
        for (tracker.outgoing.keys()) |conn| {
            const conn_tracker = self.connman.tracker_map.get(conn.end.win_id) orelse continue;
            try list.append(conn_tracker.win);
        }
    }

    for (list.items) |window| try self.selection.addWindow(window);
}

pub fn clearSelection(self: *@This()) !void {
    self.selection.wmap.clearRetainingCapacity();
}

fn toggleWindowFromSelection(ctx: *anyopaque, window: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.selection.toggleWindow(window);
}
