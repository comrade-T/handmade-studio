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
const WM = WindowManager;

////////////////////////////////////////////////////////////////////////////////////////////// ConnectionManager struct

wm: *WindowManager,

connections: ConnectionPtrMap = ConnectionPtrMap{},
tracker_map: TrackerMap = TrackerMap{},

pending_connection: ?Connection = null,
pending_connection_initial_window: ?*WM.Window = null,

cycle_map: CycleMap = CycleMap{},
cycle_index: usize = 0,

pub fn deinit(self: *@This()) void {
    for (self.tracker_map.values()) |*tracker| {
        tracker.deinit(self.wm.a);
    }
    self.tracker_map.deinit(self.wm.a);

    for (self.connections.keys()) |conn| self.wm.a.destroy(conn);
    self.connections.deinit(self.wm.a);

    self.cycle_map.deinit(self.wm.a);
}

pub fn render(self: *const @This()) void {
    const selconn = if (self.cycle_map.values().len > 0) blk: {
        assert(self.cycle_index < self.cycle_map.values().len);
        break :blk self.cycle_map.keys()[self.cycle_index];
    } else null;

    for (self.connections.keys()) |conn| {
        if (selconn) |selected| {
            if (conn == selected) {
                conn.render(self.wm, Connection.SELECTED_THICKNESS);
                conn.renderPendingIndicators(self.wm);
                continue;
            }
        }
        conn.render(self.wm, Connection.NORMAL_THICKNESS);
    }

    if (self.pending_connection) |*pc| pc.renderPendingIndicators(self.wm);
}

pub fn swapSelectedConnectionPoints(self: *@This()) !void {
    if (self.cycle_map.values().len == 0) return;
    const selconn = self.cycle_map.keys()[self.cycle_index];
    selconn.swapPoints();
}

pub fn undo(self: *@This()) !void {
    try self.wm.undo();
}

pub fn redo(self: *@This()) !void {
    try self.wm.redo();
}

////////////////////////////////////////////////////////////////////////////////////////////// Connection struct

const ConnectionPtrMap = std.AutoArrayHashMapUnmanaged(*Connection, void);
pub const Connection = struct {
    start: Point,
    end: Point,
    hidden: bool = false,

    fn new(start_win_id: i128) Connection {
        return Connection{
            .start = .{ .win_id = start_win_id },
            .end = .{ .win_id = start_win_id },
        };
    }

    const CONNECTION_COLOR = 0xffffffff;
    const MAGENTA = 0xd11daaff;
    const CYAN = 0x03d3fcff;
    const CONNECTION_START_POINT_COLOR = MAGENTA;
    const CONNECTION_END_POINT_COLOR = CYAN;

    const NORMAL_THICKNESS = 1;
    const SELECTED_THICKNESS = 5;

    fn calculateAngle(self: *const @This(), win_id: i128, wm: *const WindowManager) f32 {
        const start_point, const end_point = if (win_id == self.start.win_id) .{ self.start, self.end } else .{ self.end, self.start };
        const start_x, const start_y = (start_point.getPosition(wm) catch return 0) orelse return 0;
        const end_x, const end_y = (end_point.getPosition(wm) catch return 0) orelse return 0;

        const deltaX = end_x - start_x;
        const deltaY = end_y - start_y;
        return std.math.atan2(deltaX, deltaY) * 180 / std.math.pi;
    }

    fn render(self: *const @This(), wm: *const WindowManager, thickness: f32) void {
        if (self.hidden) return;
        const start_x, const start_y = (self.start.getPosition(wm) catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition(wm) catch return assert(false)) orelse return;
        wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, thickness, CONNECTION_COLOR);
        self.drawArrowhead(wm, start_x, start_y, end_x, end_y);
    }

    fn drawArrowhead(self: *const @This(), wm: *const WindowManager, start_x: f32, start_y: f32, end_x: f32, end_y: f32) void {
        _ = self;

        const ARROWHEAD_ANGLE = 20.0; // in degrees
        const ARROWHEAD_LINE_LENGTH = 10.0; // length of the arrowhead lines
        const ARROWHEAD_THICKNESS = 1;

        const angle = std.math.atan2(end_y - start_y, end_x - start_x);
        const left_angle = angle + (ARROWHEAD_ANGLE * std.math.pi) / 180.0;
        const right_angle = angle - (ARROWHEAD_ANGLE * std.math.pi) / 180.0;

        const left_x = end_x - ARROWHEAD_LINE_LENGTH * @cos(left_angle);
        const left_y = end_y - ARROWHEAD_LINE_LENGTH * @sin(left_angle);
        const right_x = end_x - ARROWHEAD_LINE_LENGTH * @cos(right_angle);
        const right_y = end_y - ARROWHEAD_LINE_LENGTH * @sin(right_angle);

        // Draw the two lines for the arrowhead
        wm.mall.rcb.drawLine(end_x, end_y, left_x, left_y, ARROWHEAD_THICKNESS, CONNECTION_COLOR);
        wm.mall.rcb.drawLine(end_x, end_y, right_x, right_y, ARROWHEAD_THICKNESS, CONNECTION_COLOR);
    }

    fn renderPendingIndicators(self: *const @This(), wm: *const WindowManager) void {
        if (self.hidden) return;
        const start_x, const start_y = (self.start.getPosition(wm) catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition(wm) catch return assert(false)) orelse return;
        wm.mall.rcb.drawCircle(start_x, start_y, 10, CONNECTION_START_POINT_COLOR);
        wm.mall.rcb.drawCircle(end_x, end_y, 10, CONNECTION_END_POINT_COLOR);
    }

    fn swapPoints(self: *@This()) void {
        const old = self.*;
        self.start = old.end;
        self.end = old.start;
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

    pub fn isVisible(self: *const @This(), wm: *const WindowManager) bool {
        const start_tracker = wm.connman.tracker_map.get(self.start.win_id) orelse return false;
        const end_tracker = wm.connman.tracker_map.get(self.end.win_id) orelse return false;
        return !self.hidden and !start_tracker.win.closed and !end_tracker.win.closed;
    }

    const Point = struct {
        win_id: i128,
        anchor: Anchor = .E,

        fn getPosition(self: *const @This(), wm: *const WindowManager) error{TrackerNotFound}!?struct { f32, f32 } {
            const tracker = wm.connman.tracker_map.get(self.win_id) orelse return error.TrackerNotFound;
            const win = tracker.win;
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

////////////////////////////////////////////////////////////////////////////////////////////// Pending Connection

pub fn switchPendingConnectionEndWindow(self: *@This(), direction: WM.WindowRelativeDirection) void {
    if (self.pending_connection) |*pc| {
        const start_b4 = self.tracker_map.get(pc.start.win_id) orelse return;
        const end_b4 = self.tracker_map.get(pc.end.win_id) orelse return;

        const init_is_end = if (end_b4.win == self.pending_connection_initial_window.?) true else false;
        const candidate_starting_point = if (init_is_end) start_b4.win else end_b4.win;
        _, const may_candidate = self.wm.findClosestWindowToDirection(candidate_starting_point, direction);

        if (may_candidate) |candidate| {
            if (!init_is_end or (start_b4.win == end_b4.win)) {
                pc.end.win_id = candidate.id;
            } else {
                pc.start.win_id = candidate.id;
            }

            const start = self.tracker_map.get(pc.start.win_id) orelse return;
            const end = self.tracker_map.get(pc.end.win_id) orelse return;
            pc.start.anchor, pc.end.anchor = calculateOptimalAnchorPoints(start.win, end.win);

            // should start on left side, should end at right side.
            const angle = pc.calculateAngle(pc.start.win_id, self.wm);
            if (angle < 0) pc.swapPoints();
        }
    }
}

fn calculateOptimalAnchorPoints(a: *const WM.Window, b: *const WM.Window) struct { Connection.Anchor, Connection.Anchor } {
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
    self.pending_connection = Connection.new(active_window.id);
    self.pending_connection_initial_window = active_window;
}

pub fn confirmPendingConnection(self: *@This()) !void {
    const pc = self.pending_connection orelse return;
    if (pc.start.win_id == pc.end.win_id) return;

    defer self.cleanUpAfterPendingConnection();
    try self.addConnection(pc, true);
}

pub fn swapPendingConnectionPoints(self: *@This()) !void {
    if (self.pending_connection) |*pc| pc.swapPoints();
}

pub fn cancelPendingConnection(self: *@This()) !void {
    self.cleanUpAfterPendingConnection();
}

fn cleanUpAfterPendingConnection(self: *@This()) void {
    self.pending_connection = null;
    self.pending_connection_initial_window = null;
}

////////////////////////////////////////////////////////////////////////////////////////////// Trackers

const TrackerMap = std.AutoArrayHashMapUnmanaged(WM.Window.ID, WindowConnectionsTracker);
const WindowConnectionsTracker = struct {
    win: *WM.Window,
    incoming: ConnectionPtrMap = ConnectionPtrMap{},
    outgoing: ConnectionPtrMap = ConnectionPtrMap{},

    fn deinit(self: *@This(), a: Allocator) void {
        self.incoming.deinit(a);
        self.outgoing.deinit(a);
    }
};

pub fn registerWindow(self: *@This(), window: *WM.Window) !void {
    try self.tracker_map.put(self.wm.a, window.id, ConnectionManager.WindowConnectionsTracker{ .win = window });
}

pub fn addConnection(self: *@This(), conn: Connection, add_to_history: bool) !void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win_id) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win_id) orelse return;

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
    var tracker = self.tracker_map.getPtr(win.id) orelse return;
    defer {
        tracker.deinit(self.wm.a);
        assert(self.tracker_map.swapRemove(win.id));
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
    if (!conn.isVisible(self.wm)) self.removeConnection(conn);
}

fn removeConnection(self: *@This(), conn: *Connection) void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win_id) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win_id) orelse return;

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
    if (self.shouldStopSeeking()) return;
    if (self.cycle_index + 1 >= self.cycle_map.count()) return;
    self.cycle_index += 1;
    self.seekToPrevVisibleCandidate();
}

fn seekToPrevVisibleCandidate(self: *@This()) void {
    if (self.shouldStopSeeking()) return;
    if (self.cycle_index == 0) return;
    self.cycle_index -= 1;
    self.seekToNextVisibleCandidate();
}

fn shouldStopSeeking(self: *@This()) bool {
    if (self.cycle_map.count() == 0) return true;
    if (self.cycle_index >= self.cycle_map.count()) {
        self.cycle_index = 0;
        return true;
    }
    if (!self.cycle_map.keys()[self.cycle_index].hidden) return true;
    return false;
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
    const tracker = self.tracker_map.getPtr(win.id) orelse return;
    if (tracker.incoming.keys().len == 0 and tracker.outgoing.keys().len == 0) return;

    self.cycle_map.deinit(self.wm.a);
    self.cycle_map = std.AutoArrayHashMapUnmanaged(*Connection, f32){};

    for (tracker.incoming.keys()) |c| try self.cycle_map.put(self.wm.a, c, c.calculateAngle(win.id, self.wm));
    for (tracker.outgoing.keys()) |c| try self.cycle_map.put(self.wm.a, c, c.calculateAngle(win.id, self.wm));

    const SortContext = struct {
        angles: []const f32,
        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return ctx.angles[a_index] > ctx.angles[b_index];
        }
    };

    self.cycle_map.sort(SortContext{ .angles = self.cycle_map.values() });
}
