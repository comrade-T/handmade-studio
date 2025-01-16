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

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *const WindowManager,

connections: ConnectionPtrList = ConnectionPtrList{},
tracker_map: TrackerMap = TrackerMap{},
pending_connection: ?Connection = null,
selected_query: ?SelectedConnectionQuery = null,

pub fn deinit(self: *@This()) void {
    for (self.tracker_map.values()) |*tracker| {
        tracker.incoming.deinit(self.wm.a);
        tracker.outgoing.deinit(self.wm.a);
    }
    self.tracker_map.deinit(self.wm.a);

    for (self.connections.items) |conn| self.wm.a.destroy(conn);
    self.connections.deinit(self.wm.a);
}

pub fn render(self: *const @This()) void {
    connections: {
        var selected_connection: ?*Connection = null;
        if (self.selected_query) |query| {
            const active_window = self.wm.active_window orelse break :connections;
            const tracker = self.tracker_map.getPtr(active_window.id) orelse break :connections;

            const source = switch (query.kind) {
                .start => tracker.incoming,
                .end => tracker.outgoing,
            };
            selected_connection = source.items[query.index];
        }

        for (self.connections.items) |conn| {
            if (selected_connection) |selconn| {
                if (conn == selconn) {
                    conn.render(self.wm, Connection.SELECTED_THICKNESS);
                    continue;
                }
            }
            conn.render(self.wm, Connection.NORMAL_THICKNESS);
        }
    }
    if (self.pending_connection) |*pc| pc.renderPendingConnectionIndicators(self.wm);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const ConnectionPtrList = std.ArrayListUnmanaged(*Connection);
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

    fn render(self: *const @This(), wm: *const WindowManager, thickness: f32) void {
        const start_x, const start_y = self.start.getPosition(wm) catch return assert(false);
        const end_x, const end_y = self.end.getPosition(wm) catch return assert(false);
        wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, thickness, CONNECTION_COLOR);
    }

    fn renderPendingConnectionIndicators(self: *const @This(), wm: *const WindowManager) void {
        const start_x, const start_y = self.start.getPosition(wm) catch return assert(false);
        const end_x, const end_y = self.end.getPosition(wm) catch return assert(false);
        wm.mall.rcb.drawCircle(start_x, start_y, 10, CONNECTION_START_POINT_COLOR);
        wm.mall.rcb.drawCircle(end_x, end_y, 10, CONNECTION_END_POINT_COLOR);
    }

    const Point = struct {
        win_id: i128,
        anchor: Anchor = .E,

        fn getPosition(self: *const @This(), wm: *const WindowManager) error{TrackerNotFound}!struct { f32, f32 } {
            const tracker = wm.connman.tracker_map.get(self.win_id) orelse return error.TrackerNotFound;
            const win = tracker.win;
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

pub fn switchPendingConnectionEndWindow(self: *@This(), direction: WM.WindowRelativeDirection) void {
    if (self.pending_connection) |*pc| {
        const initial_end = self.tracker_map.get(pc.end.win_id) orelse return;
        const may_candidate = self.wm.findClosestWindow(initial_end.win, direction);
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

pub fn startPendingConnection(self: *@This()) void {
    const active_window = self.wm.active_window orelse return;
    self.pending_connection = Connection.new(active_window.id);
}

pub fn confirmPendingConnection(self: *@This()) !void {
    const pc = self.pending_connection orelse return;
    if (pc.start.win_id == pc.end.win_id) return;

    defer self.pending_connection = null;
    try self.notifyTrackers(pc);
}

pub fn cancelPendingConnection(self: *@This()) void {
    self.pending_connection = null;
}

///////////////////////////// WindowConnectionsTracker

const TrackerMap = std.AutoArrayHashMapUnmanaged(WM.Window.ID, WindowConnectionsTracker);
pub const WindowConnectionsTracker = struct {
    win: *WM.Window,
    incoming: ConnectionPtrList = ConnectionPtrList{},
    outgoing: ConnectionPtrList = ConnectionPtrList{},
};

pub fn notifyTrackers(self: *@This(), conn: Connection) !void {
    var start_tracker = self.tracker_map.getPtr(conn.start.win_id) orelse return;
    var end_tracker = self.tracker_map.getPtr(conn.end.win_id) orelse return;

    const c = try self.wm.a.create(Connection);
    c.* = conn;
    try self.connections.append(self.wm.a, c);

    try start_tracker.outgoing.append(self.wm.a, c);
    try end_tracker.incoming.append(self.wm.a, c);
}

///////////////////////////// Select Connections

const SelectedConnectionQuery = struct {
    kind: enum { start, end },
    index: usize,
};

pub const PrevOrNext = enum { prev, next };

pub fn exitConnectionCycleMode(self: *@This()) void {
    self.selected_query = null;
}

pub fn cycleThroughActiveWindowConnections(self: *@This(), direction: PrevOrNext) !void {
    const active_window = self.wm.active_window orelse return;
    const tracker = self.tracker_map.getPtr(active_window.id) orelse return;

    if (tracker.incoming.items.len == 0 and tracker.outgoing.items.len == 0) return;

    if (self.selected_query) |*query| {
        switch (direction) {
            .prev => {
                switch (query.kind) {
                    .start => {
                        assert(tracker.incoming.items.len > 0);
                        if (query.index > 0) {
                            query.index -= 1;
                            return;
                        }
                        if (tracker.outgoing.items.len > 0) {
                            query.kind = .end;
                            query.index = tracker.outgoing.items.len - 1;
                        }
                        query.index = tracker.incoming.items.len - 1;
                        return;
                    },
                    .end => {
                        assert(tracker.outgoing.items.len > 0);
                        if (query.index > 0) {
                            query.index -= 1;
                            return;
                        }
                        if (tracker.incoming.items.len > 0) {
                            query.kind = .end;
                            query.index = tracker.incoming.items.len - 1;
                        }
                        query.index = tracker.outgoing.items.len - 1;
                        return;
                    },
                }
            },
            .next => {
                switch (query.kind) {
                    .start => {
                        assert(tracker.incoming.items.len > 0);
                        if (query.index + 1 < tracker.incoming.items.len) {
                            query.index += 1;
                            return;
                        }
                        if (tracker.outgoing.items.len > 0) query.kind = .end;
                        query.index = 0;
                        return;
                    },
                    .end => {
                        assert(tracker.outgoing.items.len > 0);
                        if (query.index + 1 < tracker.outgoing.items.len) {
                            query.index += 1;
                            return;
                        }
                        if (tracker.incoming.items.len > 0) query.kind = .start;
                        query.index = 0;
                        return;
                    },
                }
            },
        }
    }

    assert(self.selected_query == null);
    assert(tracker.incoming.items.len > 0 or tracker.outgoing.items.len > 0);
    self.selected_query = .{
        .index = 0,
        .kind = if (tracker.incoming.items.len > 0) .start else .end,
    };
}
