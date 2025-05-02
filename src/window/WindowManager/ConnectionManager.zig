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

const ConnectionManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const WindowManager = @import("../WindowManager.zig");
const Window = WindowManager.Window;
pub const ArrowheadManager = @import("ArrowheadManager.zig");

////////////////////////////////////////////////////////////////////////////////////////////// ConnectionManager struct

const DEFAULT_CONNECTION_THICKNESS = 1;
const DEFAULT_SELECTED_CONNECTION_THICKNESS = 1;
const SELECTED_CONNECTION_THICKNESS_WHEN_SETTING_ARRROWHEAD = DEFAULT_CONNECTION_THICKNESS;

const DEFAULT_CONNECTION_COLOR = 0xffffffff;
// const SELECTED_CONNECTION_COLOR_WHEN_SETTING_ARRROWHEAD = 0xffffffaa;
const SELECTED_CONNECTION_COLOR_WHEN_SETTING_ARRROWHEAD = 0xffffffff;

wm: *WindowManager,
ama: ArrowheadManager,
default_arrowhead_index: u32 = 1,

connection_thickness: f32 = DEFAULT_CONNECTION_THICKNESS,
selected_connection_thickness: f32 = DEFAULT_SELECTED_CONNECTION_THICKNESS,
connection_color: u32 = DEFAULT_CONNECTION_COLOR,
selected_connection_color: u32 = DEFAULT_CONNECTION_COLOR,

setting_arrowhead: bool = false,

connections: ConnectionPtrMap = ConnectionPtrMap{},
tracker_map: TrackerMap = TrackerMap{},

pending_connection: ?Connection = null,
pending_connection_initial_window: ?*Window = null,

cycle_map: CycleMap = CycleMap{},
cycle_index: usize = 0,

pub fn init(a: Allocator, wm: *WindowManager) !ConnectionManager {
    const ama = try ArrowheadManager.init(a);
    return ConnectionManager{
        .wm = wm,
        .ama = ama,
    };
}

pub fn deinit(self: *@This()) void {
    for (self.tracker_map.values()) |*tracker| {
        tracker.deinit(self.wm.a);
    }
    self.tracker_map.deinit(self.wm.a);

    for (self.connections.keys()) |conn| self.wm.a.destroy(conn);
    self.connections.deinit(self.wm.a);

    self.cycle_map.deinit(self.wm.a);
    self.ama.deinit();
}

pub fn render(self: *const @This()) void {
    const selconn = if (self.cycle_map.values().len > 0) blk: {
        assert(self.cycle_index < self.cycle_map.values().len);
        break :blk self.cycle_map.keys()[self.cycle_index];
    } else null;

    for (self.connections.keys()) |conn| {
        if (selconn) |selected| {
            if (conn == selected) {
                conn.render(self, true);
                if (!self.setting_arrowhead) conn.renderPendingIndicators(self.wm);
                continue;
            }
        }
        conn.render(self, false);
    }

    if (self.pending_connection) |*pc| pc.renderPendingIndicators(self.wm);
}

////////////////////////////////////////////////////////////////////////////////////////////// Selected Connection

pub fn swapSelectedConnectionPoints(self: *@This()) !void {
    const selconn = self.getSelectedConnection() orelse return;
    selconn.swapPoints(self);

    self.wm.cleanUpAfterAppendingToHistory(
        self.wm.a,
        try self.wm.hm.addSwapSelectedConnectionPointsEvent(self.wm.a, selconn),
    );
}

pub fn setSelectedConnectionArrowhead(self: *@This(), new_index: u32) !void {
    if (self.ama.elders.items.len == 0) return;
    const selconn = self.getSelectedConnection() orelse return;
    const old_index = selconn.arrowhead_index;
    if (old_index == new_index) return;

    selconn.arrowhead_index = new_index;

    self.wm.cleanUpAfterAppendingToHistory(
        self.wm.a,
        try self.wm.hm.addSetConnectionArrowheadEvent(self.wm.a, selconn, old_index, new_index),
    );
}

pub fn startSettingArrowhead(self: *@This()) !void {
    self.setting_arrowhead = true;
    self.selected_connection_color = SELECTED_CONNECTION_COLOR_WHEN_SETTING_ARRROWHEAD;
    self.selected_connection_thickness = SELECTED_CONNECTION_THICKNESS_WHEN_SETTING_ARRROWHEAD;
}
pub fn stopSettingArrowhead(self: *@This()) !void {
    self.setting_arrowhead = false;
    self.selected_connection_color = DEFAULT_CONNECTION_COLOR;
    self.selected_connection_thickness = DEFAULT_SELECTED_CONNECTION_THICKNESS;
}

pub fn undo(self: *@This()) !void {
    try self.wm.undo();
}

pub fn redo(self: *@This()) !void {
    try self.wm.redo();
}

pub const AlignConnectionKind = enum { horizontal, vertical };
pub const AlignConnectionAnchor = enum { start, end };
pub fn alignSelectedConnectionWindows(
    self: *@This(),
    kind: AlignConnectionKind,
    anchor: AlignConnectionAnchor,
) !void {
    const conn = self.getSelectedConnection() orelse return;

    const mover = if (anchor == .start) conn.end.win else conn.start.win;
    const target = if (anchor == .start) conn.start.win else conn.end.win;

    try self.wm.alignWindows(mover, target, kind);
}

////////////////////////////////////////////////////////////////////////////////////////////// Connection struct

const ConnectionPtrMap = std.AutoArrayHashMapUnmanaged(*Connection, void);
pub const Connection = struct {
    // TODO: reduce the size of this struct by moving the .anchor field out of the Point struct.

    start: Point,
    end: Point,
    hidden: bool = false,
    arrowhead_index: u32 = 0,

    fn new(win: *Window) Connection {
        return Connection{
            .start = .{ .win = win },
            .end = .{ .win = win },
        };
    }

    const MAGENTA = 0xd11daaff;
    const CYAN = 0x03d3fcff;
    const CONNECTION_START_POINT_COLOR = MAGENTA;
    const CONNECTION_END_POINT_COLOR = CYAN;

    fn calculateAngle(self: *const @This(), win: *Window) f32 {
        const start_point, const end_point = if (win == self.start.win) .{ self.start, self.end } else .{ self.end, self.start };
        const start_x, const start_y = (start_point.getPosition() catch return 0) orelse return 0;
        const end_x, const end_y = (end_point.getPosition() catch return 0) orelse return 0;

        const deltaX = end_x - start_x;
        const deltaY = end_y - start_y;
        return std.math.atan2(deltaX, deltaY) * 180 / std.math.pi;
    }

    fn render(self: *const @This(), connman: *const ConnectionManager, selected: bool) void {
        if (self.hidden) return;
        const thickness = if (selected) connman.selected_connection_thickness else connman.connection_thickness;
        const color = if (selected) connman.selected_connection_color else connman.connection_color;

        const start_x, const start_y = (self.start.getPosition() catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition() catch return assert(false)) orelse return;
        connman.wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, thickness, color);

        const ah = if (self.arrowhead_index > 0)
            connman.ama.getElder(self.arrowhead_index) orelse unreachable
        else
            connman.ama.getElder(connman.default_arrowhead_index) orelse return;
        ah.render(start_x, start_y, end_x, end_y, connman.wm.mall);
    }

    fn renderPendingIndicators(self: *const @This(), wm: *const WindowManager) void {
        if (self.hidden) return;
        const start_x, const start_y = (self.start.getPosition() catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition() catch return assert(false)) orelse return;
        wm.mall.rcb.drawCircle(start_x, start_y, 10, CONNECTION_START_POINT_COLOR);
        wm.mall.rcb.drawCircle(end_x, end_y, 10, CONNECTION_END_POINT_COLOR);
    }

    fn swapPointsOnly(self: *@This()) void {
        const old = self.*;
        self.start = old.end;
        self.end = old.start;
    }

    pub fn swapPoints(self: *@This(), connman: *ConnectionManager) void {
        var initial_start_tracker = connman.tracker_map.getPtr(self.start.win) orelse return;
        var initial_end_tracker = connman.tracker_map.getPtr(self.end.win) orelse return;

        self.swapPointsOnly();

        assert(initial_start_tracker.outgoing.swapRemove(self));
        initial_start_tracker.incoming.put(connman.wm.a, self, {}) catch unreachable;

        assert(initial_end_tracker.incoming.swapRemove(self));
        initial_end_tracker.outgoing.put(connman.wm.a, self, {}) catch unreachable;
    }

    pub fn show(self: *@This(), connman: *ConnectionManager) void {
        self.hidden = false;
        for (connman.cycle_map.keys(), 0..) |conn, i| {
            if (conn == self) {
                connman.cycle_index = i;
                break;
            }
        }
    }

    pub fn hide(self: *@This()) void {
        self.hidden = true;
    }

    pub fn isVisible(self: *const @This()) bool {
        return !self.hidden and !self.start.win.closed and !self.end.win.closed;
    }

    const Point = struct {
        win: *Window,
        anchor: Anchor = .E,

        fn getPosition(self: *const @This()) error{TrackerNotFound}!?struct { f32, f32 } {
            const win = self.win;
            if (win.closed) return null;
            switch (self.anchor) {
                .N => return .{ win.attr.pos.x + win.getWidth() / 2, win.attr.pos.y },
                .E => return .{ win.attr.pos.x + win.getWidth(), win.attr.pos.y + win.getHeight() / 2 },
                .S => return .{ win.attr.pos.x + win.getWidth() / 2, win.attr.pos.y + win.getHeight() },
                .W => return .{ win.attr.pos.x, win.attr.pos.y + win.getHeight() / 2 },
            }
            unreachable;
        }
    };
    pub const Anchor = enum { N, E, S, W };
};

///////////////////////////// Persistent

pub const PersistentConnection = struct {
    start: PersistentPoint,
    end: PersistentPoint,
    hidden: bool = false,
    arrowhead_index: u32 = 0,

    pub fn fromExistingConnection(conn: *const Connection) PersistentConnection {
        return PersistentConnection{
            .start = .{
                .win_id = conn.start.win.id,
                .anchor = conn.start.anchor,
            },
            .end = .{
                .win_id = conn.end.win.id,
                .anchor = conn.end.anchor,
            },
            .hidden = conn.hidden,
            .arrowhead_index = conn.arrowhead_index,
        };
    }

    const PersistentPoint = struct {
        win_id: Window.ID,
        anchor: Connection.Anchor,
    };
};

////////////////////////////////////////////////////////////////////////////////////////////// Pending Connection

pub fn setPendingConnectionArrowhead(self: *@This(), index: u32) void {
    if (self.pending_connection) |*pc| pc.arrowhead_index = index;
}

pub fn switchPendingConnectionEndWindow(self: *@This(), direction: WindowManager.WindowRelativeDirection) void {
    if (self.pending_connection) |*pc| {
        const start_b4 = pc.start.win;
        const end_b4 = pc.end.win;

        const init_is_end = if (end_b4 == self.pending_connection_initial_window.?) true else false;
        const candidate_starting_point = if (init_is_end) start_b4 else end_b4;
        _, const may_candidate = self.wm.findClosestWindowToDirection(candidate_starting_point, direction);

        if (may_candidate) |candidate| {
            if (!init_is_end or (start_b4 == end_b4)) {
                pc.end.win = candidate;
            } else {
                pc.start.win = candidate;
            }

            pc.start.anchor, pc.end.anchor = calculateOptimalAnchorPoints(pc.start.win, pc.end.win);

            // should start on left side, should end at right side.
            const angle = pc.calculateAngle(pc.start.win);
            if (angle < 0) pc.swapPointsOnly();
        }
    }
}

fn calculateOptimalAnchorPoints(a: *const Window, b: *const Window) struct { Connection.Anchor, Connection.Anchor } {
    const cx_a = a.getX() + a.getWidth() / 2;
    const cy_a = a.getY() + a.getHeight() / 2;
    const cx_b = b.getX() + b.getWidth() / 2;
    const cy_b = b.getY() + b.getHeight() / 2;

    const x_diff = @abs(cx_a - cx_b);
    const y_diff = @abs(cy_a - cy_b);

    var anchor_a = Connection.Anchor.E;
    var anchor_b = Connection.Anchor.E;

    if (x_diff >= y_diff) {
        if (cx_a > cx_b) {
            anchor_a = .W;
            anchor_b = .E;
        } else {
            anchor_a = .E;
            anchor_b = .W;
        }
    } else {
        if (cy_a > cy_b) {
            anchor_a = .N;
            anchor_b = .S;
        } else {
            anchor_a = .S;
            anchor_b = .N;
        }
    }

    return .{ anchor_a, anchor_b };
}

pub fn startPendingConnection(self: *@This()) !void {
    const active_window = self.wm.active_window orelse return;
    self.pending_connection = Connection.new(active_window);
    self.pending_connection_initial_window = active_window;
}

pub fn confirmPendingConnection(self: *@This()) !void {
    const pc = self.pending_connection orelse return;
    if (pc.start.win == pc.end.win) return;

    defer self.cleanUpAfterPendingConnection();
    try self.addConnection(pc, true);
}

pub fn swapPendingConnectionPoints(self: *@This()) !void {
    if (self.pending_connection) |*pc| pc.swapPointsOnly();
}

pub fn cancelPendingConnection(self: *@This()) !void {
    self.cleanUpAfterPendingConnection();
}

pub fn establishHardCodedPendingConnection(
    self: *@This(),
    a: *Window,
    a_anchor: Connection.Anchor,
    b: *Window,
    b_anchor: Connection.Anchor,
) !void {
    self.pending_connection = Connection.new(a);
    self.pending_connection_initial_window = a;

    self.pending_connection.?.start.anchor = a_anchor;
    self.pending_connection.?.end = .{ .win = b, .anchor = b_anchor };

    try self.confirmPendingConnection();
}

fn cleanUpAfterPendingConnection(self: *@This()) void {
    self.pending_connection = null;
    self.pending_connection_initial_window = null;
}

////////////////////////////////////////////////////////////////////////////////////////////// Trackers

const TrackerMap = std.AutoArrayHashMapUnmanaged(*Window, Tracker);
const Tracker = struct {
    incoming: ConnectionPtrMap = ConnectionPtrMap{},
    outgoing: ConnectionPtrMap = ConnectionPtrMap{},

    fn deinit(self: *@This(), a: Allocator) void {
        self.incoming.deinit(a);
        self.outgoing.deinit(a);
    }
};

pub fn registerWindow(self: *@This(), window: *Window) !void {
    try self.tracker_map.put(self.wm.a, window, Tracker{});
}

pub fn addConnection(self: *@This(), conn: Connection, add_to_history: bool) !void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win) orelse return;

    const c = try self.wm.a.create(Connection);
    c.* = conn;
    try self.connections.put(self.wm.a, c, {});

    try start_tracker.outgoing.put(self.wm.a, c, {});
    try end_tracker.incoming.put(self.wm.a, c, {});

    if (add_to_history) {
        self.wm.cleanUpAfterAppendingToHistory(
            self.wm.a,
            try self.wm.hm.addAddConnectionEvent(self.wm.a, c),
        );
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Remove all connections of a window

pub fn removeAllConnectionsOfWindow(self: *@This(), win: *WindowManager.Window) void {
    var tracker = self.tracker_map.getPtr(win) orelse return;
    defer {
        tracker.deinit(self.wm.a);
        assert(self.tracker_map.swapRemove(win));
    }
    for (tracker.incoming.keys()) |conn| self.removeConnection(conn);
    for (tracker.outgoing.keys()) |conn| self.removeConnection(conn);
}

////////////////////////////////////////////////////////////////////////////////////////////// Select Connections

const SelectedConnectionQuery = struct {
    kind: enum { start, end },
    index: usize,
};
const PrevOrNext = enum { prev, next };

///////////////////////////// delete selected connection

pub fn hideSelectedConnection(self: *@This()) !void {
    const conn = self.getSelectedConnection() orelse return;
    conn.hide();

    self.wm.cleanUpAfterAppendingToHistory(
        self.wm.a,
        try self.wm.hm.addHideConnectionEvent(self.wm.a, conn),
    );

    self.seekToNextVisibleCandidate();
}

pub fn cleanUpConnectionAfterAppendingToHistory(self: *@This(), conn: *Connection) void {
    if (!conn.isVisible()) self.removeConnection(conn);
}

fn removeConnection(self: *@This(), conn: *Connection) void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win) orelse return;

    _ = start_tracker.outgoing.swapRemove(conn);
    _ = end_tracker.incoming.swapRemove(conn);
    _ = self.connections.swapRemove(conn);
    _ = self.cycle_map.orderedRemove(conn);

    self.wm.a.destroy(conn);

    self.seekToNextVisibleCandidate();
}

fn getSelectedConnection(self: *@This()) ?*Connection {
    if (self.cycle_index >= self.cycle_map.values().len) return null;
    return self.cycle_map.keys()[self.cycle_index];
}

///////////////////////////// cycling methods

pub fn cycleToNextConnection(self: *@This()) !void {
    if (self.getNextAngle()) |_| self.cycle_index += 1;
    self.seekToNextVisibleCandidate();
}

pub fn cycleToPreviousConnection(self: *@This()) !void {
    if (self.getPrevAngle()) |_| self.cycle_index -= 1;
    self.seekToPrevVisibleCandidate();
}

pub fn cycleToNextDownConnection(self: *@This()) !void {
    const curr_angle = self.getCurrentAngle() orelse return;
    const may_prev_angle = self.getPrevAngle();
    const may_next_angle = self.getNextAngle();

    defer self.seekToNextVisibleCandidate();

    if (curr_angle < 0) {
        if (may_prev_angle) |prev_angle| {
            if (prev_angle >= 0) return;
            self.cycle_index -= 1;
        } else return;
    } else {
        if (may_next_angle) |next_angle| {
            if (next_angle < 0) return;
            self.cycle_index += 1;
        }
    }
}

pub fn cycleToNextUpConnection(self: *@This()) !void {
    const curr_angle = self.getCurrentAngle() orelse return;
    const may_prev_angle = self.getPrevAngle();
    const may_next_angle = self.getNextAngle();

    defer self.seekToPrevVisibleCandidate();

    if (curr_angle < 0) {
        if (may_next_angle) |next_angle| {
            if (next_angle >= 0) return;
            self.cycle_index += 1;
        } else return;
    } else {
        if (may_prev_angle) |prev_angle| {
            if (prev_angle < 0) return;
            self.cycle_index -= 1;
        }
    }
}

fn seekToNextVisibleCandidate(self: *@This()) void {
    if (self.cycle_map.count() == 0) return;
    const initial_index = self.cycle_index;
    while (self.cycle_index < self.cycle_map.count()) {
        const conn = self.cycle_map.keys()[self.cycle_index];
        if (conn.isVisible()) return;
        self.cycle_index += 1;
    }
    for (0..initial_index) |i| {
        const conn = self.cycle_map.keys()[i];
        if (conn.isVisible()) {
            self.cycle_index = i;
            return;
        }
    }
    self.cycle_index = initial_index;
}

fn seekToPrevVisibleCandidate(self: *@This()) void {
    if (self.cycle_map.count() == 0) return;
    const initial_index = self.cycle_index;
    while (self.cycle_index > 0) {
        const conn = self.cycle_map.keys()[self.cycle_index];
        if (conn.isVisible()) return;
        self.cycle_index -= 1;
    }
    for (initial_index..self.cycle_map.count()) |i| {
        const conn = self.cycle_map.keys()[i];
        if (conn.isVisible()) {
            self.cycle_index = i;
            return;
        }
    }
    self.cycle_index = initial_index;
}

fn getPrevAngle(self: *@This()) ?f32 {
    if (self.cycle_index == 0) return null;
    return self.cycle_map.values()[self.cycle_index - 1];
}

fn getNextAngle(self: *@This()) ?f32 {
    if (self.cycle_index + 1 >= self.cycle_map.values().len) return null;
    return self.cycle_map.values()[self.cycle_index + 1];
}

fn getCurrentAngle(self: *@This()) ?f32 {
    if (self.cycle_index >= self.cycle_map.values().len) return null;
    return self.cycle_map.values()[self.cycle_index];
}

pub fn cycleToLeftMirroredConnection(self: *@This()) !void {
    const angle = self.getCurrentAngle() orelse return;
    if (angle > 0) self.cycleToMirrorredConnection();
    self.seekToNextVisibleCandidate();
}

pub fn cycleToRightMirroredConnection(self: *@This()) !void {
    const angle = self.getCurrentAngle() orelse return;
    if (angle < 0) self.cycleToMirrorredConnection();
    self.seekToPrevVisibleCandidate();
}

fn cycleToMirrorredConnection(self: *@This()) void {
    if (self.cycle_map.values().len < 2) return;
    const mirrored_angle = self.cycle_map.values()[self.cycle_index] * -1;

    // TODO: handle hidden connections

    var new_cycle_index: usize = 0;
    var min_distance: f32 = std.math.floatMax(f32);
    for (self.cycle_map.values(), 0..) |angle, i| {
        if (self.cycle_index == i) continue;

        if ((angle >= 0 and mirrored_angle >= 0) or (angle < 0 and mirrored_angle < 0)) {
            const d = @abs(angle - mirrored_angle);
            if (d < min_distance) {
                min_distance = d;
                new_cycle_index = i;
            }
        }
    }

    self.cycle_index = new_cycle_index;
}

///////////////////////////// enter / exit cycling

pub fn enterCycleMode(self: *@This()) !void {
    try self.updateCycleMap();
    self.cycle_index = 0;
    self.seekToNextVisibleCandidate();
}

pub fn exitCycleMode(self: *@This()) !void {
    self.cycle_map.clearRetainingCapacity();
}

const CycleMap = std.AutoArrayHashMapUnmanaged(*Connection, f32);
fn updateCycleMap(self: *@This()) !void {
    const win = self.wm.active_window orelse return;
    const tracker = self.tracker_map.getPtr(win) orelse return;
    if (tracker.incoming.keys().len == 0 and tracker.outgoing.keys().len == 0) return;

    self.cycle_map.deinit(self.wm.a);
    self.cycle_map = std.AutoArrayHashMapUnmanaged(*Connection, f32){};

    for (tracker.incoming.keys()) |c| try self.cycle_map.put(self.wm.a, c, c.calculateAngle(win));
    for (tracker.outgoing.keys()) |c| try self.cycle_map.put(self.wm.a, c, c.calculateAngle(win));

    const SortContext = struct {
        angles: []const f32,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.angles[a_index] > ctx.angles[b_index];
        }
    };

    self.cycle_map.sort(SortContext{ .angles = self.cycle_map.values() });
}
