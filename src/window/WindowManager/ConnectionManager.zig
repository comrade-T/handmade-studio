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

////////////////////////////////////////////////////////////////////////////////////////////// Mappings

pub fn mapKeys(connman: *@This(), council: *WM.MappingCouncil) !void {

    ///////////////////////////// modes & contexts involved

    const NORMAL = "normal";
    const CYCLING = "cycling_connections";
    const PENDING = "pending_connection";

    const NORMAL_TO_CYCLING = WM.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{CYCLING} };
    const CYCLING_TO_NORMAL = WM.Callback.Contexts{ .remove = &.{CYCLING}, .add = &.{NORMAL} };

    const NORMAL_TO_PENDING = WM.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{PENDING} };
    const PENDING_TO_NORMAL = WM.Callback.Contexts{ .remove = &.{PENDING}, .add = &.{NORMAL} };

    ///////////////////////////// cycling connections

    try council.map(NORMAL, &.{ .c, .l }, .{ .f = enterCycleMode, .ctx = connman, .contexts = NORMAL_TO_CYCLING });
    try council.map(CYCLING, &.{.escape}, .{ .f = exitCycleMode, .ctx = connman, .contexts = CYCLING_TO_NORMAL });
    try council.map(CYCLING, &.{.j}, .{ .f = cycleToNextDownConnection, .ctx = connman });
    try council.map(CYCLING, &.{.k}, .{ .f = cycleToNextUpConnection, .ctx = connman });
    try council.map(CYCLING, &.{.h}, .{ .f = cycleToLeftMirroredConnection, .ctx = connman });
    try council.map(CYCLING, &.{.l}, .{ .f = cycleToRightMirroredConnection, .ctx = connman });
    try council.map(CYCLING, &.{.n}, .{ .f = cycleToNextConnection, .ctx = connman });
    try council.map(CYCLING, &.{.p}, .{ .f = cycleToPreviousConnection, .ctx = connman });
    try council.map(CYCLING, &.{.backspace}, .{ .f = removeSelectedConnection, .ctx = connman });
    try council.map(CYCLING, &.{.delete}, .{ .f = removeSelectedConnection, .ctx = connman });

    ///////////////////////////// pending connection

    try council.map(NORMAL, &.{ .left_control, .c }, .{ .f = startPendingConnection, .ctx = connman, .contexts = NORMAL_TO_PENDING });
    try council.map(PENDING, &.{.escape}, .{ .f = cancelPendingConnection, .ctx = connman, .contexts = PENDING_TO_NORMAL });
    try council.map(PENDING, &.{.enter}, .{ .f = confirmPendingConnection, .ctx = connman, .contexts = PENDING_TO_NORMAL });

    // change target window

    const ChangeConnectionEndWinIDCb = struct {
        direction: WM.WindowRelativeDirection,
        connman: *ConnectionManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            self.connman.switchPendingConnectionEndWindow(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, cm_: *ConnectionManager, direction: WindowManager.WindowRelativeDirection) !WM.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .direction = direction, .connman = cm_ };
            return WM.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map(PENDING, &.{ .left_control, .h }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), connman, .left));
    try council.map(PENDING, &.{ .left_control, .l }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), connman, .right));
    try council.map(PENDING, &.{ .left_control, .k }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), connman, .top));
    try council.map(PENDING, &.{ .left_control, .j }, try ChangeConnectionEndWinIDCb.init(council.arena.allocator(), connman, .bottom));

    // change anchor

    const ChangeConnectionAnchorCb = struct {
        const Which = enum { start, end };
        which: Which,
        anchor: Connection.Anchor,
        connman: *ConnectionManager,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            if (self.connman.pending_connection == null) return;
            switch (self.which) {
                .start => self.connman.pending_connection.?.start.anchor = self.anchor,
                .end => self.connman.pending_connection.?.end.anchor = self.anchor,
            }
        }
        pub fn init(allocator: std.mem.Allocator, cm_: *ConnectionManager, which: Which, anchor: Connection.Anchor) !WM.Callback {
            const self = try allocator.create(@This());
            self.* = .{ .which = which, .anchor = anchor, .connman = cm_ };
            return WM.Callback{ .f = @This().f, .ctx = self };
        }
    };
    try council.map(PENDING, &.{ .s, .h }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .start, .W));
    try council.map(PENDING, &.{ .s, .l }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .start, .E));
    try council.map(PENDING, &.{ .s, .k }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .start, .N));
    try council.map(PENDING, &.{ .s, .j }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .start, .S));
    try council.map(PENDING, &.{ .e, .h }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .end, .W));
    try council.map(PENDING, &.{ .e, .l }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .end, .E));
    try council.map(PENDING, &.{ .e, .k }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .end, .N));
    try council.map(PENDING, &.{ .e, .j }, try ChangeConnectionAnchorCb.init(council.arena.allocator(), connman, .end, .S));
}

////////////////////////////////////////////////////////////////////////////////////////////// ConnectionManager struct

wm: *const WindowManager,

connections: ConnectionPtrMap = ConnectionPtrMap{},
tracker_map: TrackerMap = TrackerMap{},
pending_connection: ?Connection = null,

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
                continue;
            }
        }
        conn.render(self.wm, Connection.NORMAL_THICKNESS);
    }

    if (self.pending_connection) |*pc| pc.renderPendingIndicators(self.wm);
}

////////////////////////////////////////////////////////////////////////////////////////////// Connection struct

const ConnectionPtrMap = std.AutoArrayHashMapUnmanaged(*Connection, void);
pub const Connection = struct {
    start: Point,
    end: Point,

    fn new(start_win_id: i128) Connection {
        return Connection{
            .start = .{ .win_id = start_win_id },
            .end = .{ .win_id = start_win_id },
        };
    }

    const CONNECTION_COLOR = 0xffffffff;
    const CONNECTION_START_POINT_COLOR = 0x03d3fcff;
    const CONNECTION_END_POINT_COLOR = 0xd11daaff;

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
        const start_x, const start_y = (self.start.getPosition(wm) catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition(wm) catch return assert(false)) orelse return;
        wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, thickness, CONNECTION_COLOR);
    }

    fn renderPendingIndicators(self: *const @This(), wm: *const WindowManager) void {
        const start_x, const start_y = (self.start.getPosition(wm) catch return assert(false)) orelse return;
        const end_x, const end_y = (self.end.getPosition(wm) catch return assert(false)) orelse return;
        wm.mall.rcb.drawCircle(start_x, start_y, 10, CONNECTION_START_POINT_COLOR);
        wm.mall.rcb.drawCircle(end_x, end_y, 10, CONNECTION_END_POINT_COLOR);
    }

    pub fn isVisible(self: *const @This(), wm: *const WindowManager) bool {
        const start_tracker = wm.connman.tracker_map.get(self.start.win_id) orelse return false;
        const end_tracker = wm.connman.tracker_map.get(self.end.win_id) orelse return false;
        return !start_tracker.win.closed and !end_tracker.win.closed;
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

fn switchPendingConnectionEndWindow(self: *@This(), direction: WM.WindowRelativeDirection) void {
    if (self.pending_connection) |*pc| {
        const initial_end = self.tracker_map.get(pc.end.win_id) orelse return;
        _, const may_candidate = self.wm.findClosestWindowToDirection(initial_end.win, direction);
        if (may_candidate) |candidate| {
            pc.end.win_id = candidate.id;
            const start = self.tracker_map.get(pc.start.win_id) orelse return;
            const end = self.tracker_map.get(pc.end.win_id) orelse return;
            pc.start.anchor, pc.end.anchor = calculateOptimalAnchorPoints(start.win, end.win);
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

fn startPendingConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const active_window = self.wm.active_window orelse return;
    self.pending_connection = Connection.new(active_window.id);
}

fn confirmPendingConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const pc = self.pending_connection orelse return;
    if (pc.start.win_id == pc.end.win_id) return;

    defer self.pending_connection = null;
    try self.notifyTrackers(pc);
}

fn cancelPendingConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.pending_connection = null;
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

pub fn notifyTrackers(self: *@This(), conn: Connection) !void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win_id) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win_id) orelse return;

    const c = try self.wm.a.create(Connection);
    c.* = conn;
    try self.connections.put(self.wm.a, c, {});

    try start_tracker.outgoing.put(self.wm.a, c, {});
    try end_tracker.incoming.put(self.wm.a, c, {});
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

fn removeSelectedConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const conn = self.getSelectedConnection() orelse return;
    self.removeConnection(conn);
}

fn removeConnection(self: *@This(), conn: *Connection) void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win_id) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win_id) orelse return;

    _ = start_tracker.outgoing.swapRemove(conn);
    _ = end_tracker.incoming.swapRemove(conn);
    _ = self.connections.swapRemove(conn);
    _ = self.cycle_map.orderedRemove(conn);
    self.cycle_index -|= 1;

    self.wm.a.destroy(conn);
}

fn getSelectedConnection(self: *@This()) ?*Connection {
    if (self.cycle_index >= self.cycle_map.values().len) return null;
    return self.cycle_map.keys()[self.cycle_index];
}

///////////////////////////// cycling methods

fn cycleToNextConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.getNextAngle()) |_| self.cycle_index += 1;
}

fn cycleToPreviousConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.getPrevAngle()) |_| self.cycle_index -= 1;
}

fn cycleToNextDownConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const curr_angle = self.getCurrentAngle() orelse return;
    const may_prev_angle = self.getPrevAngle();
    const may_next_angle = self.getNextAngle();

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

fn cycleToNextUpConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const curr_angle = self.getCurrentAngle() orelse return;
    const may_prev_angle = self.getPrevAngle();
    const may_next_angle = self.getNextAngle();

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

fn cycleToLeftMirroredConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const angle = self.getCurrentAngle() orelse return;
    if (angle > 0) self.cycleToMirrorredConnection();
}

fn cycleToRightMirroredConnection(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const angle = self.getCurrentAngle() orelse return;
    if (angle < 0) self.cycleToMirrorredConnection();
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

fn enterCycleMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.updateCycleMap();
    self.cycle_index = 0;
}

fn exitCycleMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
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
