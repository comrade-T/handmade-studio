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

const HistoryManager = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowManager = @import("../WindowManager.zig");
const Window = WindowManager.Window;
const Connection = WindowManager.ConnectionManager.Connection;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
capacity: usize,
index: i64 = -1,
events: std.MultiArrayList(Event) = .{},
wmap: std.AutoHashMapUnmanaged(*Window, usize) = .{},
last_edit: i64 = 0,

pub const Event = union(enum) {
    spawn: *Window,
    close: *Window,
    toggle_border: *Window,
    change_padding: struct { win: *Window, x_by: f32, y_by: f32 },
    move: struct { win: *Window, x_by: f32, y_by: f32 },

    add_connection: *Connection,
    hide_connection: *Connection,
    swap_selected_connection_points: *Connection,
    set_connection_arrowhead: struct { conn: *Connection, prev: u32, next: u32 },
};

pub fn deinit(self: *@This()) void {
    self.events.deinit(self.a);
    self.wmap.deinit(self.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn batchUndo(self: *@This()) struct { i64, i64 } {
    if (self.index == -1 or self.events.len == 0) return .{ -1, -1 };

    const index_tag = @tagName(self.events.get(@intCast(self.index)));

    var target_index: i64 = -1;
    var i: i64 = self.index - 1;
    while (i > -1) {
        defer i -= 1;
        assert(i >= -1);
        const tag = @tagName(self.events.get(@intCast(i)));
        if (!std.mem.eql(u8, tag, index_tag)) {
            target_index = i;
            break;
        }
    }

    defer self.index = target_index;
    return .{ self.index, target_index };
}

pub fn batchRedo(self: *@This()) struct { i64, i64 } {
    if (self.events.len == 0) return .{ -1, -1 };
    if (self.index + 1 >= self.events.len) return .{ -1, -1 };

    self.index += 1;
    const index_tag = @tagName(self.events.get(@intCast(self.index)));

    var target_index: i64 = @intCast(self.events.len - 1);
    var i: i64 = self.index + 1;
    while (i < self.events.len) {
        defer i += 1;
        assert(i < self.events.len);
        const tag = @tagName(self.events.get(@intCast(i)));
        if (!std.mem.eql(u8, tag, index_tag)) {
            target_index = i;
            break;
        }
    }

    defer self.index = target_index;
    return .{ self.index, target_index };
}

pub fn undo(self: *@This()) ?Event {
    if (self.index < 0 or self.events.len == 0) return null;
    defer self.updateLastEditTimestamp();
    defer {
        self.index -= 1;
        assert(self.index >= -1);
    }
    return self.events.get(@intCast(self.index));
}

pub fn redo(self: *@This()) ?Event {
    if (self.events.len == 0) return null;
    if (self.index + 1 < self.events.len) {
        self.index += 1;
        assert(self.index >= 0);
        return self.events.get(@intCast(self.index));
    }
    return null;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const AddNewEventResult = struct {
    windows_to_cleanup: []*Window,
    connections_to_cleanup: []*Connection,
};

pub fn addSpawnEvent(self: *@This(), a: Allocator, win: *Window) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .spawn = win });
}

pub fn addCloseEvent(self: *@This(), a: Allocator, win: *Window) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .close = win });
}

pub fn addToggleBorderEvent(self: *@This(), a: Allocator, win: *Window) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .toggle_border = win });
}

pub fn addChangePaddingEvent(self: *@This(), a: Allocator, win: *Window, x_by: f32, y_by: f32) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .change_padding = .{ .win = win, .x_by = x_by, .y_by = y_by } });
}

pub fn addMoveEvent(self: *@This(), a: Allocator, win: *Window, x_by: f32, y_by: f32) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .move = .{ .win = win, .x_by = x_by, .y_by = y_by } });
}

/////////////////////////////

pub fn addAddConnectionEvent(self: *@This(), a: Allocator, conn: *Connection) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .add_connection = conn });
}

pub fn addHideConnectionEvent(self: *@This(), a: Allocator, conn: *Connection) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .hide_connection = conn });
}

pub fn addSwapSelectedConnectionPointsEvent(self: *@This(), a: Allocator, conn: *Connection) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .swap_selected_connection_points = conn });
}

pub fn addSetConnectionArrowheadEvent(self: *@This(), a: Allocator, conn: *Connection, prev: u32, next: u32) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .set_connection_arrowhead = .{ .conn = conn, .prev = prev, .next = next } });
}

////////////////////////////////////////////////////////////////////////////////////////////// internal

fn updateLastEditTimestamp(self: *@This()) void {
    self.last_edit = std.time.microTimestamp();
}

fn addNewEvent(self: *@This(), a: Allocator, new_event: Event) !AddNewEventResult {
    assert(self.capacity > 0);
    assert(self.index == 0 or self.index < self.events.len);
    assert(self.events.len <= self.capacity);

    defer self.updateLastEditTimestamp();

    var windows_to_cleanup = std.ArrayListUnmanaged(*Window){};
    var connections_to_cleanup = std.ArrayListUnmanaged(*Connection){};
    var overcap = false;

    ///////////////////////////// if the needle (index) is in the middle, chop off the rest of the history

    if (self.events.len > 0 and self.index <= self.events.len - 1) {
        var i: usize = self.events.len;
        while (i > self.index + 1) {
            defer i -= 1;
            const old_event = self.events.pop() orelse break;
            try self.handleChopAndOvercap(a, &windows_to_cleanup, &connections_to_cleanup, old_event, new_event);
        }
    }

    ///////////////////////////// if reached max capacity, remove first history in the list

    if (self.events.len + 1 >= self.capacity) {
        overcap = true;
        const old_event = self.events.get(0);

        try self.handleChopAndOvercap(a, &windows_to_cleanup, &connections_to_cleanup, old_event, new_event);
        self.events.orderedRemove(0);
    }

    /////////////////////////////

    if (!overcap) self.index += 1;
    assert(self.index < self.capacity - 1);

    try self.events.append(self.a, new_event);
    try self.addEventToWindowMap(new_event);

    return AddNewEventResult{
        .windows_to_cleanup = try windows_to_cleanup.toOwnedSlice(a),
        .connections_to_cleanup = try connections_to_cleanup.toOwnedSlice(a),
    };
}

fn addEventToWindowMap(self: *@This(), ev: Event) !void {
    const win = getWindowFromEvent(ev) orelse return;

    if (!self.wmap.contains(win)) {
        try self.wmap.put(self.a, win, 1);
        return;
    }

    const count = self.wmap.getPtr(win) orelse return;
    count.* += 1;
}

fn handleChopAndOvercap(
    self: *@This(),
    a: Allocator,
    windows_to_cleanup: *std.ArrayListUnmanaged(*Window),
    connections_to_cleanup: *std.ArrayListUnmanaged(*Connection),
    old_event: Event,
    new_event: Event,
) !void {
    if (getConnectionFromEvent(old_event)) |old_conn| {
        const may_new_conn = getConnectionFromEvent(new_event);
        if (may_new_conn == null or may_new_conn.? != old_conn)
            try connections_to_cleanup.append(a, old_conn);
        return;
    }

    /////////////////////////////

    const win = getWindowFromEvent(old_event) orelse unreachable;
    assert(self.wmap.contains(win));

    const count = self.wmap.getPtr(win) orelse unreachable;
    assert(count.* > 0);

    if (count.* == 1) {
        const may_new_win = getWindowFromEvent(new_event);
        if (may_new_win == null or win != may_new_win.?)
            try windows_to_cleanup.append(a, win);

        const removed = self.wmap.remove(win);
        assert(removed);
        return;
    }
    count.* -= 1;
}

fn getConnectionFromEvent(ev: Event) ?*Connection {
    return switch (ev) {
        .add_connection,
        .hide_connection,
        .swap_selected_connection_points,
        => |conn| conn,

        .set_connection_arrowhead => |info| info.conn,

        else => null,
    };
}

fn getWindowFromEvent(ev: Event) ?*Window {
    return switch (ev) {
        .spawn, .close, .toggle_border => |win| win,
        .change_padding => |info| info.win,
        .move => |info| info.win,
        else => null,
    };
}
