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
const RenderMall = @import("RenderMall");
const AnchorPicker = @import("AnchorPicker");
pub const WindowSource = @import("WindowSource");
pub const Window = @import("Window");

const ip_ = @import("input_processor");
pub const MappingCouncil = ip_.MappingCouncil;
pub const Callback = ip_.Callback;

const ConnectionManager = @import("WindowManager/ConnectionManager.zig");
const vim_related = @import("WindowManager/vim_related.zig");
const layout_related = @import("WindowManager/layout_related.zig");

////////////////////////////////////////////////////////////////////////////////////////////// mapKeys

pub fn mapKeys(self: *@This(), ap: *const AnchorPicker, council: *MappingCouncil) !void {
    try self.connman.mapKeys(council);
    try vim_related.mapKeys(self, council);
    try layout_related.mapKeys(self, council);

    try self.mapSessionRelatedKeymaps(council);
    try self.mapSpawnBlankWindowKeymaps(ap, council);
}

const NORMAL = "normal";

fn mapSessionRelatedKeymaps(self: *@This(), council: *MappingCouncil) !void {
    try council.map(NORMAL, &.{ .left_control, .left_shift, .p }, .{ .f = saveSession, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_control, .p }, .{ .f = saveSession, .ctx = self });

    try council.map(NORMAL, &.{ .left_control, .left_shift, .l }, .{ .f = loadSession, .ctx = self });
    try council.map(NORMAL, &.{ .left_shift, .left_control, .l }, .{ .f = loadSession, .ctx = self });
}

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

                try self.wm.spawnWindow(.string, "", .{ .pos = .{ .x = x, .y = y } }, true);
                return;
            }

            try self.wm.spawnNewWindowRelativeToActiveWindow(.string, "", .{}, self.direction);
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

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,

active_window: ?*Window = null,

handlers: WindowSourceHandlerList = WindowSourceHandlerList{},
last_win_id: i128 = Window.UNSET_WIN_ID,

fmap: FilePathToHandlerMap = FilePathToHandlerMap{},
wmap: WindowToHandlerMap = WindowToHandlerMap{},

connman: ConnectionManager,

pub fn create(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall) !*WindowManager {
    const self = try a.create(@This());
    self.* = WindowManager{
        .a = a,
        .lang_hub = lang_hub,
        .mall = style_store,
        .connman = ConnectionManager{ .wm = self },
    };
    return self;
}

pub fn render(self: *@This()) void {
    for (self.wmap.keys()) |window| {
        const is_active = if (self.active_window) |active_window| active_window == window else false;
        window.render(is_active, self.mall);
    }
    self.connman.render();
}

pub fn destroy(self: *@This()) void {
    self.connman.deinit();

    for (self.handlers.items) |handler| handler.destroy(self.a);
    self.handlers.deinit(self.a);

    self.fmap.deinit(self.a);
    self.wmap.deinit(self.a);

    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowSourceHandler

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerList = std.ArrayListUnmanaged(*WindowSourceHandler);
const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowList,

    const WindowList = std.ArrayListUnmanaged(*Window);

    fn create(wm: *WindowManager, from: WindowSource.InitFrom, source: []const u8, lang_hub: *LangHub) !*WindowSourceHandler {
        const self = try wm.a.create(@This());
        self.* = WindowSourceHandler{
            .source = try WindowSource.create(wm.a, from, source, lang_hub),
            .windows = WindowList{},
        };
        return self;
    }

    fn destroy(self: *@This(), a: Allocator) void {
        for (self.windows.items) |window| window.destroy();
        self.windows.deinit(a);
        self.source.destroy();
        a.destroy(self);
    }

    fn spawnWindow(self: *@This(), wm: *WindowManager, opts: Window.SpawnOptions) !*Window {
        const window = try Window.create(wm.a, self.source, opts, wm.mall);
        try self.windows.append(wm.a, window);

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
};

////////////////////////////////////////////////////////////////////////////////////////////// Make closest window active

pub fn findClosestWindow(self: *const @This(), curr: *const Window, direction: WindowRelativeDirection) ?*Window {
    const ccx, const ccy = getWidowCenterCoordinates(curr);

    var inter_xd: f32 = std.math.floatMax(f32);
    var inter_yd: f32 = std.math.floatMax(f32);
    var inter_candidate: ?*Window = null;

    var loose_xd: f32 = std.math.floatMax(f32);
    var loose_yd: f32 = std.math.floatMax(f32);
    var loose_candidate: ?*Window = null;

    for (self.wmap.keys()) |window| {
        if (window == curr) continue;

        switch (direction) {
            .right, .left => {
                const cond = if (direction == .right)
                    window.attr.pos.x > curr.attr.pos.x
                else
                    window.attr.pos.x < curr.attr.pos.x;

                if (cond) {
                    if (window.verticalIntersect(curr)) {
                        const xd = @abs(window.attr.pos.x - curr.attr.pos.x);
                        if (xd < inter_xd) {
                            inter_candidate = window;
                            inter_xd = xd;
                        }
                    }

                    if (inter_candidate != null) continue;

                    const xd, const yd = calculateCenterDistaceBetweenWindows(window, ccx, ccy);
                    if (totalDistanceIsSmaller(xd, yd, loose_xd, loose_yd)) {
                        loose_xd, loose_yd = .{ xd, yd };
                        loose_candidate = window;
                    }
                }
            },

            .bottom, .top => {
                const cond = if (direction == .bottom)
                    window.attr.pos.y > curr.attr.pos.y
                else
                    window.attr.pos.y < curr.attr.pos.y;

                if (cond) {
                    if (window.horizontalIntersect(curr)) {
                        const yd = @abs(window.attr.pos.y - curr.attr.pos.y);
                        if (yd < inter_yd) {
                            inter_candidate = window;
                            inter_yd = yd;
                        }
                    }

                    if (inter_candidate != null) continue;

                    const xd, const yd = calculateCenterDistaceBetweenWindows(window, ccx, ccy);
                    if (totalDistanceIsSmaller(xd, yd, loose_xd, loose_yd)) {
                        loose_xd, loose_yd = .{ xd, yd };
                        loose_candidate = window;
                    }
                }
            },
        }
    }

    return if (inter_candidate != null) inter_candidate else loose_candidate;
}

fn getWidowCenterCoordinates(win: *const Window) struct { f32, f32 } {
    return .{
        win.getX() + win.getWidth() / 2,
        win.getY() + win.getHeight() / 2,
    };
}

fn calculateCenterDistaceBetweenWindows(this: *const Window, other_cx: f32, other_cy: f32) struct { f32, f32 } {
    const tcx, const tcy = getWidowCenterCoordinates(this);
    return .{
        @abs(tcx - other_cx),
        @abs(tcy - other_cy),
    };
}

fn totalDistanceIsSmaller(xd: f32, yd: f32, cxd: f32, cyd: f32) bool {
    return (xd + yd) < (cxd + cyd);
}

////////////////////////////////////////////////////////////////////////////////////////////// Spawn

pub fn spawnWindowFromHandler(self: *@This(), handler: *WindowSourceHandler, opts: Window.SpawnOptions, make_active: bool) !void {
    const window = try handler.spawnWindow(self, opts);
    try self.wmap.put(self.a, window, handler);
    if (make_active or self.active_window == null) self.active_window = window;
}

pub fn spawnWindow(self: *@This(), from: WindowSource.InitFrom, source: []const u8, opts: Window.SpawnOptions, make_active: bool) !void {

    // if file path exists in fmap
    if (from == .file) {
        if (self.fmap.get(source)) |handler| {
            const window = try handler.spawnWindow(self, opts);
            try self.wmap.put(self.a, window, handler);
            if (make_active or self.active_window == null) self.active_window = window;
            return;
        }
    }

    // spawn from scratch
    try self.handlers.append(self.a, try WindowSourceHandler.create(self, from, source, self.lang_hub));
    var handler = self.handlers.getLast();

    const window = try handler.spawnWindow(self, opts);
    try self.wmap.put(self.a, window, handler);

    if (from == .file) try self.fmap.put(self.a, handler.source.path, handler);

    if (make_active or self.active_window == null) self.active_window = window;
}

test spawnWindow {
    var lang_hub = try LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    const style_store = try RenderMall.createStyleStoreForTesting(testing_allocator);
    defer RenderMall.freeTestStyleStore(testing_allocator, style_store);

    {
        var wm = try WindowManager.init(testing_allocator, &lang_hub, style_store);
        defer wm.deinit();

        // spawn .string Window
        try wm.spawnWindow(.string, "hello world", .{});
        try eq(1, wm.handlers.items.len);
        try eq(1, wm.wmap.values().len);
        try eq(0, wm.fmap.values().len);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Auto Layout

pub const WindowRelativeDirection = enum { left, right, top, bottom };

pub fn spawnNewWindowRelativeToActiveWindow(
    self: *@This(),
    from: WindowSource.InitFrom,
    source: []const u8,
    opts: Window.SpawnOptions,
    direction: WindowRelativeDirection,
) !void {
    const prev = self.active_window orelse return;

    try self.spawnWindow(from, source, opts, true);
    const new = self.active_window orelse unreachable;

    var new_x: f32 = new.attr.target_pos.x;
    var new_y: f32 = new.attr.target_pos.y;
    switch (direction) {
        .right => {
            new_x = prev.attr.pos.x + prev.cached.width;
            new_y = prev.attr.pos.y;
        },
        .left => {
            new_x = prev.attr.pos.x - new.cached.width;
            new_y = prev.attr.pos.y;
        },
        .bottom => {
            new_x = prev.attr.pos.x;
            new_y = prev.attr.pos.y + prev.cached.height;
        },
        .top => {
            new_x = prev.attr.pos.x;
            new_y = prev.attr.pos.y - new.cached.height;
        },
    }
    new.setPosition(new_x, new_y);

    for (self.wmap.keys()) |window| {
        if (window == prev or window == new) continue;
        switch (direction) {
            .right => {
                if (window.attr.pos.x > prev.attr.pos.x and window.verticalIntersect(prev)) {
                    window.moveBy(new.cached.width, 0);
                }
            },
            .left => {
                if (window.attr.pos.x < prev.attr.pos.x and
                    window.verticalIntersect(prev))
                    window.moveBy(-new.cached.width, 0);
            },
            .bottom => {
                if (window.attr.pos.y > prev.attr.pos.y and
                    window.horizontalIntersect(prev))
                    window.moveBy(0, new.cached.height);
            },
            .top => {
                if (window.attr.pos.y < prev.attr.pos.y and
                    window.horizontalIntersect(prev))
                    window.moveBy(0, -new.cached.height);
            },
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Session

const session_file_path = ".handmade_studio/session.json";

const StringSource = struct {
    id: i128,
    contents: []const u8,
};

const Session = struct {
    string_sources: []const StringSource,
    connections: []*const ConnectionManager.Connection,
    windows: []const Window.WritableWindowState,
};

pub fn loadSession(ctx: *anyopaque) !void {

    ///////////////////////////// read file & parse

    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    const file = std.fs.cwd().openFile(session_file_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("catched err: {any} --> returning.\n", .{err});
        return;
    };
    defer file.close();
    const stat = try file.stat();

    const buf = try self.a.alloc(u8, stat.size);
    defer self.a.free(buf);
    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    const parsed = try std.json.parseFromSlice(Session, self.a, buf, .{});
    defer parsed.deinit();

    ///////////////////////////// create handlers & spawn windows

    var strid_to_handler_map = std.AutoArrayHashMap(i128, *WindowSourceHandler).init(self.a);
    defer strid_to_handler_map.deinit();

    for (parsed.value.string_sources) |str_source| {
        const handler = try WindowSourceHandler.create(self, .string, str_source.contents, self.lang_hub);
        try self.handlers.append(self.a, handler);
        try strid_to_handler_map.put(str_source.id, handler);
    }

    for (parsed.value.windows) |state| {
        switch (state.source) {
            .file => |path| try self.spawnWindow(.file, path, state.opts, true),
            .string => |string_id| {
                const handler = strid_to_handler_map.get(string_id) orelse continue;
                try self.spawnWindowFromHandler(handler, state.opts, true);
            },
        }
    }

    for (parsed.value.connections) |conn| try self.connman.notifyTrackers(conn.*);
}

pub fn saveSession(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var string_source_list = std.ArrayList(StringSource).init(self.a);
    defer string_source_list.deinit();

    var window_to_id_map = std.AutoArrayHashMap(*Window, i128).init(self.a);
    defer window_to_id_map.deinit();

    ///////////////////////////// handle string sources

    var last_id: i128 = std.math.maxInt(i128);
    for (self.handlers.items) |handler| {
        if (handler.source.from == .file) continue;

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

        for (handler.windows.items) |window| {
            try window_to_id_map.put(window, id);
        }
    }

    /////////////////////////////

    var window_state_list = std.ArrayList(Window.WritableWindowState).init(self.a);
    defer window_state_list.deinit();

    for (self.wmap.keys()) |window| {
        const string_id: ?i128 = window_to_id_map.get(window) orelse null;
        const data = try window.produceWritableState(string_id);
        try window_state_list.append(data);
    }

    /////////////////////////////

    const session = Session{
        .windows = window_state_list.items,
        .string_sources = string_source_list.items,
        .connections = self.connman.connections.items,
    };

    const str = try std.json.stringifyAlloc(arena.allocator(), session, .{
        .whitespace = .indent_4,
    });

    try writeToFile(str);
    std.debug.print("session written to file successfully\n", .{});
}

fn writeToFile(str: []const u8) !void {
    var file = try std.fs.cwd().createFile(session_file_path, .{});
    defer file.close();
    try file.writeAll(str);
}
