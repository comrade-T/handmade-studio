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
last_string_source_id: i128 = 0,

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
window_picker_normal_no_center_cam: WindowPicker,
vertical_justify_target_picker: WindowPicker,

selection: Selection,

yanker: Yanker,

cursor_animator_map: Window.CursorAnimatorMap = .{},

// temporary solution for LSP
post_file_open_callback_func: ?*const fn (ctx: *anyopaque, win: *Window) anyerror!void = null,
post_file_open_callback_ctx: *anyopaque = undefined,

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

        .window_picker_normal = WindowPicker{ .wm = self, .callback = .{ .f = setActiveWindowPickerCallback, .ctx = self } },
        .selection_window_picker = WindowPicker{ .wm = self, .callback = .{ .f = toggleWindowFromSelection, .ctx = self } },
        .window_picker_normal_no_center_cam = WindowPicker{
            .wm = self,
            .callback = .{ .f = setActiveWindowPickerCallbackNoCenterCam, .ctx = self },
            .hide_active_window_label = true,
        },
        .vertical_justify_target_picker = WindowPicker{
            .wm = self,
            .callback = .{ .f = verticalJustifyTargetPickerCallback, .ctx = self },
            .hide_selection_window_labels = true,
        },

        .selection = try Selection.init(a),

        .yanker = Yanker{ .wm = self },
    };
    return self;
}

pub fn updateAndRender(self: *@This()) !void {
    {
        const windows_to_be_updated = self.updating_windows_map.keys();
        var i: usize = windows_to_be_updated.len;
        while (i > 0) {
            i -= 1;
            try windows_to_be_updated[i].update(self.a, self.qtree, &self.updating_windows_map);
        }
    }
    {
        var i: usize = self.cursor_animator_map.count();
        while (i > 0) {
            i -= 1;
            if (self.cursor_animator_map.values()[i].isFinished()) {
                self.cursor_animator_map.swapRemoveAt(i);
            }
        }
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
        const may_cursor_animator = self.cursor_animator_map.getPtr(window);
        window.render(.{
            .mall = self.mall,
            .active = is_active,
            .selected = is_selected,
            .view = null,
            .cursor_animator = may_cursor_animator,
        });
    }

    // std.debug.print("#wins: {d} | visible on screen: {d} | #windows in tree: {d}\n", .{
    //     self.wmap.keys().len,
    //     self.visible_windows.items.len,
    //     self.qtree.getNumberOfItems(),
    // });
    self.connman.render();

    self.window_picker_normal.render();
    self.window_picker_normal_no_center_cam.render();
    self.selection_window_picker.render();
    self.vertical_justify_target_picker.render();
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

    self.hm.deinit();
    self.wshm.deinit();

    self.selection.deinit();
    self.yanker.map.deinit(self.a);

    self.cursor_animator_map.deinit(self.a);

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
fn setActiveWindowPickerCallbackNoCenterCam(ctx: *anyopaque, window: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.setActiveWindow(window, true);
}

pub fn undoWindowSwitch(self: *@This()) !void {
    const new_win = self.wshm.undo() orelse return;
    self.setActiveWindow(new_win, false);
    new_win.centerCameraAt(self.mall);
}
pub fn undoWindowSwitchNoCenterCam(self: *@This()) !void {
    const new_win = self.wshm.undo() orelse return;
    self.setActiveWindow(new_win, false);
}

pub fn redoWindowSwitch(self: *@This()) !void {
    const new_win = self.wshm.redo() orelse return;
    self.setActiveWindow(new_win, false);
    new_win.centerCameraAt(self.mall);
}
pub fn redoWindowSwitchNoCenterCam(self: *@This()) !void {
    const new_win = self.wshm.redo() orelse return;
    self.setActiveWindow(new_win, false);
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowSourceHandler

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerMap = std.AutoArrayHashMapUnmanaged(*WindowSourceHandler, void);
pub const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowMap,

    const WindowMap = std.AutoArrayHashMapUnmanaged(*Window, void);

    pub fn create(wm: *WindowManager, origin: WindowSource.Origin, may_string_source: ?[]const u8, lang_hub: *LangHub) !*WindowSourceHandler {
        const self = try wm.a.create(@This());
        self.* = WindowSourceHandler{
            .source = try WindowSource.create(wm.a, origin, may_string_source, lang_hub),
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
                std.Thread.sleep(1);
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
            if (self.source.origin == .file) {
                const removed_from_fmap = wm.fmap.swapRemove(self.source.origin.file);
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

pub fn spawnWindowFromHandler(self: *@This(), handler: *WindowSourceHandler, opts: Window.SpawnOptions, make_active: bool) !*Window {
    const window = try handler.spawnWindow(self, opts);
    try self.wmap.put(self.a, window, handler);
    if (make_active or self.active_window == null) self.setActiveWindow(window, true);
    return window;
}

pub fn spawnWindow(
    self: *@This(),
    origin: WindowSource.Origin,
    may_string_source: ?[]const u8,
    opts: Window.SpawnOptions,
    make_active: bool,
    add_to_history: bool,
) !*Window {

    // if file path exists in fmap
    if (origin == .file) {
        if (self.fmap.get(origin.file)) |handler| {
            const window = try handler.spawnWindow(self, opts);
            try self.wmap.put(self.a, window, handler);
            if (add_to_history) try self.addWindowsToSpawnHistory(&.{window});
            if (make_active or self.active_window == null) self.setActiveWindow(window, true);
            return window;
        }
    }

    // spawn from scratch
    var handler = try WindowSourceHandler.create(self, origin, may_string_source, self.lang_hub);
    try self.handlers.put(self.a, handler, {});

    const window = try handler.spawnWindow(self, opts);
    if (add_to_history) try self.addWindowsToSpawnHistory(&.{window});
    try self.wmap.put(self.a, window, handler);

    if (origin == .file) {
        try self.fmap.put(self.a, handler.source.origin.file, handler);
        if (self.post_file_open_callback_func) |f| {
            try f(self.post_file_open_callback_ctx, window);
        }
    }

    if (make_active or self.active_window == null) self.setActiveWindow(window, true);
    return window;
}

////////////////////////////////////////////////////////////////////////////////////////////// History

fn addWindowsToSpawnHistory(self: *@This(), windows: Windows) !void {
    self.cleanUpAfterAppendingToHistory(
        self.a,
        try self.hm.addSpawnEvent(self.a, windows),
    );
}

fn addWindowsToCloseHistory(self: *@This(), windows: Windows) !void {
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
        .justify => |info| for (info.window_batches, 0..) |batch, i|
            for (batch) |win|
                try win.moveBy(self.a, self.qtree, &self.updating_windows_map, -info.x_by[i], -info.y_by[i]),

        .set_default_color => |info| for (info.windows) |win| win.setDefaultColor(info.prev),

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
        .justify => |info| for (info.window_batches, 0..) |batch, i|
            for (batch) |win|
                try win.moveBy(self.a, self.qtree, &self.updating_windows_map, info.x_by[i], info.y_by[i]),

        .set_default_color => |info| for (info.windows) |win| win.setDefaultColor(info.next),

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

pub fn closeActiveWindows(self: *@This()) !void {
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

    if (add_to_history) try self.addWindowsToCloseHistory(windows);

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

pub const SpawnRelativeeWindowOpts = struct {
    move: bool = false,
    x_by: f32 = 0,
    y_by: f32 = 0,
    instant: bool = false,
    direction: WindowRelativeDirection = .bottom,
};
pub fn spawnNewWindowRelativeToActiveWindow(
    self: *@This(),
    origin: WindowSource.Origin,
    may_string_source: ?[]const u8,
    win_opts_: Window.SpawnOptions,
    spawn_opts: SpawnRelativeeWindowOpts,
) !?*Window {
    const prev = self.active_window orelse return null;

    // adjust positions of to-be-spawned window
    var win_opts = win_opts_;
    var new_x: f32 = 0;
    var new_y: f32 = 0;
    switch (spawn_opts.direction) {
        .right => {
            new_x = prev.getX() + prev.getWidth();
            new_y = prev.getY();
        },
        .left => {
            new_x = prev.getX();
            new_y = prev.getY();
        },
        .bottom => {
            new_x = prev.getX();
            new_y = prev.getY() + prev.getHeight();
        },
        .top => {
            new_x = prev.getX();
            new_y = prev.getY() - prev.getHeight();
        },
    }
    win_opts.pos = .{ .x = new_x, .y = new_y, .lerp_time = prev.attr.pos.lerp_time };

    // spawn new window
    const new_win = try self.spawnWindow(origin, may_string_source, win_opts, true, true);

    // animation vs not
    new_x += spawn_opts.x_by;
    new_y += spawn_opts.y_by;
    if (spawn_opts.instant) {
        switch (spawn_opts.direction) {
            .left => new_x -= prev.getWidth(),
            .top => new_y -= prev.getY(),
            else => {},
        }
        try new_win.setPositionInstantly(self.a, self.qtree, new_x, new_y);
    } else {
        try new_win.setTargetPosition(self.a, self.qtree, new_x, new_y);
        try self.updating_windows_map.put(self.a, new_win, {});
    }

    if (spawn_opts.move) try self.moveWindowsOutOfTheWay(prev, new_win, spawn_opts);
    return new_win;
}

fn moveWindowsOutOfTheWay(self: *@This(), prev: *Window, new_win: *Window, spawn_opts: SpawnRelativeeWindowOpts) !void {
    for (self.wmap.keys()) |window| {
        if (window == prev or window == new_win) continue;
        switch (spawn_opts.direction) {
            .right => {
                if (window.getX() > prev.getX() and window.verticalIntersect(prev)) {
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, new_win.getWidth(), 0);
                }
            },
            .left => {
                if (window.getX() < prev.getX() and
                    window.verticalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, -new_win.getWidth(), 0);
            },
            .bottom => {
                if (window.getY() > prev.getY() and
                    window.horizontalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, 0, new_win.getHeight());
            },
            .top => {
                if (window.getY() < prev.getY() and
                    window.horizontalIntersect(prev))
                    try window.moveBy(self.a, self.qtree, &self.updating_windows_map, 0, -new_win.getHeight());
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

pub fn toggleActiveWindowFromSelection(self: *@This()) !void {
    const active_window = self.active_window orelse return;
    try self.selection.toggleWindow(active_window);
}

pub fn selectAllDescendants(self: *@This()) !void {
    const active_window = self.active_window orelse return;
    var list = try self.getAllDescendants(self.a, active_window);
    defer list.deinit(self.a);
    for (list.items) |window| try self.selection.addWindow(window);
}

pub fn getAllDescendants(self: *@This(), a: Allocator, win: *Window) !std.ArrayListUnmanaged(*Window) {
    var list = std.ArrayListUnmanaged(*Window){};
    try list.append(a, win);

    var i: usize = 0;
    while (i < list.items.len) {
        defer i += 1;
        const window = list.items[i];
        const tracker = self.connman.tracker_map.get(window) orelse continue;
        for (tracker.outgoing.keys()) |conn| {
            if (!conn.isVisible()) continue;
            try list.append(a, conn.end.win);
        }
    }

    return list;
}

pub fn selectAllConnectedWindowsRecursively(self: *@This()) !void {
    const active_window = self.active_window orelse return;
    var map = std.AutoArrayHashMap(*Window, void).init(self.a);
    defer map.deinit();
    try map.put(active_window, {});

    var i: usize = 0;
    while (i < map.count()) {
        defer i += 1;
        const window = map.keys()[i];
        const tracker = self.connman.tracker_map.get(window) orelse continue;

        for ([_][]*ConnectionManager.Connection{ tracker.incoming.keys(), tracker.outgoing.keys() }) |connections| {
            for (connections) |conn| {
                if (!conn.isVisible()) continue;
                if (!map.contains(conn.start.win)) try map.put(conn.start.win, {});
                if (!map.contains(conn.end.win)) try map.put(conn.end.win, {});
            }
        }
    }

    try self.clearSelection();
    for (map.keys()) |win| try self.selection.addWindow(win);
}

pub fn selectAllChildrenOfFirstIncomingWindow(self: *@This()) !void {
    const active_window = self.active_window orelse return;
    const first_incoming_conn = self.getFirstVisibleIncomingWindow(active_window) orelse return;
    try self.selectAllChildrenOfWindow(first_incoming_conn.start.win);
}

pub fn selectAllChildrenOfWindow(self: *@This(), win: *Window) !void {
    const tracker = self.connman.tracker_map.get(win) orelse return;
    try self.clearSelection();
    for (tracker.outgoing.keys()) |conn| {
        if (!conn.isVisible()) continue;
        try self.selection.addWindow(conn.end.win);
    }
}

pub fn clearSelection(self: *@This()) !void {
    self.selection.wmap.clearRetainingCapacity();
}

pub fn addWindowsToSelection(self: *@This(), windows: []const *Window) !void {
    for (windows) |win| try self.selection.addWindow(win);
}

fn toggleWindowFromSelection(ctx: *anyopaque, window: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.selection.toggleWindow(window);
}

////////////////////////////////////////////////////////////////////////////////////////////// Flicker Strike

pub fn getFirstVisibleIncomingWindow(self: *@This(), win: *Window) ?*ConnectionManager.Connection {
    const tracker = self.connman.tracker_map.get(win) orelse return null;
    if (tracker.incoming.count() == 0) return null;

    var may_visible_index: ?usize = null;
    const keys = tracker.incoming.keys();
    for (0..tracker.incoming.count()) |i| {
        if (keys[i].isVisible()) {
            may_visible_index = i;
            break;
        }
    }

    const visible_index = may_visible_index orelse return null;
    return keys[visible_index];
}

pub fn alignAndJustifySelectionToFirstIncoming(self: *@This()) !void {
    const active_window = self.active_window orelse return;
    const first_incoming_conn = self.getFirstVisibleIncomingWindow(active_window) orelse return;
    try self.alignAndJustifySelectionVerticallyToTarget(first_incoming_conn.start.win);
}

pub fn alignWindows(self: *@This(), mover: *Window, target: *Window, kind: ConnectionManager.AlignConnectionKind) !void {
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

fn verticalJustifyTargetPickerCallback(ctx: *anyopaque, target: *Window) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.alignAndJustifySelectionVerticallyToTarget(target);
}

fn alignAndJustifySelectionVerticallyToTarget(self: *@This(), target: *Window) !void {
    if (self.selection.wmap.count() < 1) return;

    var top: f32 = std.math.floatMax(f32);
    var bottom: f32 = -std.math.floatMax(f32);
    for (self.selection.wmap.keys()) |win| {
        top = @min(top, win.getTargetY());
        bottom = @max(bottom, win.getTargetY() + win.getHeight());
    }
    const selection_center = top + ((bottom - top) / 2);
    const target_center = target.getTargetY() + (target.getHeight() / 2);
    const y_by = target_center - selection_center;

    try self.justifySelectionVertically(.{ .add_y = y_by, .sync_left = true });
}

const JustifySelectionOpts = struct {
    add_x: f32 = 0,
    add_y: f32 = 0,
    sync_left: bool = false,
};
pub fn justifySelectionVertically(self: *@This(), opts: JustifySelectionOpts) !void {
    if (self.selection.wmap.count() < 2) return;
    const window_batches = try self.a.alloc([]const *Window, self.selection.wmap.count());

    const SortCtx = struct {
        windows: []*Window,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.windows[a_index].getTargetY() < ctx.windows[b_index].getTargetY();
        }
    };
    self.selection.wmap.sort(SortCtx{ .windows = self.selection.wmap.keys() });

    const topmost_win = self.selection.wmap.keys()[0];
    const botommost_win = self.selection.wmap.keys()[self.selection.wmap.count() - 1];
    const top = topmost_win.getTargetY() + topmost_win.getHeight();
    const bottom = botommost_win.getTargetY();
    var left: f32 = std.math.floatMax(f32);
    var total_occupied_height: f32 = 0;
    for (self.selection.wmap.keys(), 0..) |win, i| {
        left = @min(left, win.getTargetX());
        if (i == 0 or i == self.selection.wmap.count() - 1) continue;
        total_occupied_height += win.getHeight();
    }
    const count = @as(f32, @floatFromInt(self.selection.wmap.count() - 1));
    const space_between = (bottom - top - total_occupied_height) / count;

    var x_slice = try self.a.alloc(f32, self.selection.wmap.count());
    var y_slice = try self.a.alloc(f32, self.selection.wmap.count());
    for (self.selection.wmap.keys(), 0..) |curr, i| {
        x_slice[i] = if (opts.sync_left) left - curr.getTargetX() else 0;
        x_slice[i] += opts.add_x;

        if (i == 0 or i == self.selection.wmap.count() - 1) {
            y_slice[i] = 0 + opts.add_y;
        } else {
            const prev_win = self.selection.wmap.keys()[i - 1];
            const target = prev_win.getTargetY() + prev_win.getHeight() + space_between;
            y_slice[i] = target - curr.getTargetY();
        }

        var windows_to_move_list = try self.getAllDescendants(self.a, curr);
        window_batches[i] = try windows_to_move_list.toOwnedSlice(self.a);
        for (window_batches[i]) |w| {
            try w.moveBy(self.a, self.qtree, &self.updating_windows_map, x_slice[i], y_slice[i]);
        }
    }

    self.cleanUpAfterAppendingToHistory(self.a, try self.hm.addJustifyEvent(self.a, .{
        .window_batches = window_batches,
        .x_by = x_slice,
        .y_by = y_slice,
    }));
}

pub fn justifySelectionHorizontally(self: *@This(), opts: JustifySelectionOpts) !void {
    if (self.selection.wmap.count() < 2) return;
    const window_batches = try self.a.alloc([]const *Window, self.selection.wmap.count());

    const SortCtx = struct {
        windows: []*Window,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.windows[a_index].getTargetX() < ctx.windows[b_index].getTargetX();
        }
    };
    self.selection.wmap.sort(SortCtx{ .windows = self.selection.wmap.keys() });

    const leftmost_win = self.selection.wmap.keys()[0];
    const rightmost_win = self.selection.wmap.keys()[self.selection.wmap.count() - 1];
    const left = leftmost_win.getTargetX() + leftmost_win.getWidth();
    const right = rightmost_win.getTargetX();
    var total_occupied_width: f32 = 0;
    for (self.selection.wmap.keys(), 0..) |win, i| {
        if (i == 0 or i == self.selection.wmap.count() - 1) continue;
        total_occupied_width += win.getWidth();
    }
    const count = @as(f32, @floatFromInt(self.selection.wmap.count() - 1));
    const space_between = (right - left - total_occupied_width) / count;

    var x_slice = try self.a.alloc(f32, self.selection.wmap.count());
    var y_slice = try self.a.alloc(f32, self.selection.wmap.count());
    for (self.selection.wmap.keys(), 0..) |curr, i| {
        y_slice[i] = 0;
        y_slice[i] += opts.add_y;

        if (i == 0 or i == self.selection.wmap.count() - 1) {
            x_slice[i] = 0 + opts.add_x;
        } else {
            const prev_win = self.selection.wmap.keys()[i - 1];
            const target = prev_win.getTargetX() + prev_win.getWidth() + space_between;
            x_slice[i] = target - curr.getTargetX();
        }

        var windows_to_move_list = try self.getAllDescendants(self.a, curr);
        window_batches[i] = try windows_to_move_list.toOwnedSlice(self.a);
        for (window_batches[i]) |w| {
            try w.moveBy(self.a, self.qtree, &self.updating_windows_map, x_slice[i], y_slice[i]);
        }
    }

    self.cleanUpAfterAppendingToHistory(self.a, try self.hm.addJustifyEvent(self.a, .{
        .window_batches = window_batches,
        .x_by = x_slice,
        .y_by = y_slice,
    }));
}

////////////////////////////////////////////////////////////////////////////////////////////// Yank & Paste Selected Windows

const YankedWindowsMap = std.AutoArrayHashMapUnmanaged(*Window, void);

const Yanker = struct {
    wm: *WindowManager,
    map: YankedWindowsMap = .{},

    pub fn yankSelectedWindows(self: *@This()) !void {
        if (self.wm.selection.isEmpty()) return;
        self.clear();
        for (self.wm.selection.wmap.keys()) |win| try self.addWindow(win);
    }

    fn hasThingsToPaste(self: *const @This()) bool {
        return self.map.count() > 0;
    }

    fn addWindow(self: *@This(), win: *Window) !void {
        try self.map.put(self.wm.a, win, {});
    }

    fn clear(self: *@This()) void {
        self.map.clearRetainingCapacity();
    }
};

pub fn paste(
    self: *@This(),
    a: Allocator,
    origin: *WindowManager,
    kind: enum { in_place, screen_center },
) ![]const *Window {
    if (!origin.yanker.hasThingsToPaste()) return &.{};

    var x_by: f32, var y_by: f32 = .{ 0, 0 };
    if (kind == .screen_center) {
        var min_left: f32 = std.math.floatMax(f32);
        var min_top: f32 = std.math.floatMax(f32);
        var max_right: f32 = -std.math.floatMax(f32);
        var max_bottom: f32 = -std.math.floatMax(f32);

        for (origin.yanker.map.keys()) |win| {
            min_left = @min(min_left, win.getX());
            min_top = @min(min_top, win.getY());
            max_right = @max(max_right, win.getX() + win.getWidth());
            max_bottom = @max(max_bottom, win.getY() + win.getHeight());
        }

        const current_center_x = min_left + ((max_right - min_left) / 2);
        const current_center_y = min_top + ((max_bottom - min_top) / 2);

        const screen_rect = self.mall.getScreenRect(self.mall.target_camera);
        const screen_center_x = screen_rect.x + screen_rect.width / 2;
        const screen_center_y = screen_rect.y + screen_rect.height / 2;

        x_by = screen_center_x - current_center_x;
        y_by = screen_center_y - current_center_y;
    }

    /////////////////////////////

    var duped_windows = try a.alloc(*Window, origin.yanker.map.count());

    for (origin.yanker.map.keys(), 0..) |target, i| {
        const new_window = try self.duplicateWindow(target, x_by, y_by);
        duped_windows[i] = new_window;
    }

    /////////////////////////////

    var connections = std.AutoArrayHashMap(ConnectionManager.Connection, void).init(self.a);
    defer connections.deinit();
    for (origin.yanker.map.keys(), 0..) |win, i| {
        const tracker = origin.connman.tracker_map.get(win) orelse unreachable;

        for (tracker.incoming.keys()) |conn| {
            var new_conn = conn.*;
            new_conn.end.win = duped_windows[i];

            if (origin.yanker.map.contains(conn.start.win)) {
                const index = origin.yanker.map.getIndex(conn.start.win) orelse unreachable;
                new_conn.start.win = duped_windows[index];
            }
            try connections.put(new_conn, {});
        }

        for (tracker.outgoing.keys()) |conn| {
            var new_conn = conn.*;
            new_conn.start.win = duped_windows[i];

            if (origin.yanker.map.contains(conn.end.win)) {
                const index = origin.yanker.map.getIndex(conn.end.win) orelse unreachable;
                new_conn.end.win = duped_windows[index];
            }
            try connections.put(new_conn, {});
        }
    }

    for (connections.keys()) |conn| try self.connman.addConnection(conn, false);

    /////////////////////////////

    const index = origin.yanker.map.getIndex(origin.active_window.?) orelse unreachable;
    self.setActiveWindow(duped_windows[index], true);

    try self.addWindowsToSpawnHistory(duped_windows);

    return duped_windows;
}

fn duplicateWindow(self: *@This(), target: *const Window, move_x_by: f32, move_y_by: f32) !*Window {
    var opts = target.produceSpawnOptions();
    opts.id = null;
    opts.pos.x += move_x_by;
    opts.pos.y += move_y_by;

    return switch (target.ws.origin) {
        .file => |path| self.spawnWindow(.{ .file = path }, null, opts, false, false),
        .string => blk: {
            const str_contents = try target.ws.buf.ropeman.toString(self.a, .lf);
            defer self.a.free(str_contents);
            const new_win = self.spawnWindow(.{ .string = self.getNewStringSourceID() }, str_contents, opts, false, false);
            break :blk new_win;
        },
    };
}

////////////////////////////////////////////////////////////////////////////////////////////// Animate Cursor

const CursorAnimator = Window.CursorAnimator;
pub fn triggerCursorEnterAnimation(self: *@This(), win: *Window) !void {
    try self.cursor_animator_map.put(self.a, win, .{
        .progress = CursorAnimator.ENTER_START,
        .kind = .enter,
        .lerp_time = 0.1,
    });
}
pub fn triggerCursorExitAnimation(self: *@This(), win: *Window) !void {
    try self.cursor_animator_map.put(self.a, win, .{
        .progress = CursorAnimator.EXIT_START,
        .kind = .exit,
        .lerp_time = 0.3,
    });
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn getNewStringSourceID(self: *@This()) i128 {
    var id = std.time.nanoTimestamp();
    while (true) {
        if (id != self.last_win_id) break;
        std.Thread.sleep(1);
        id = std.time.nanoTimestamp();
    }
    self.last_win_id = id;
    return id;
}
