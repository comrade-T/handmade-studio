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
wmap: std.AutoArrayHashMapUnmanaged(*Window, usize) = .{},
last_edit: i64 = 0,

pub const Windows = []const *Window;
const JustifyEvent = struct {
    windows: Windows,
    x_by: []const f32,
    y_by: []const f32,

    fn free(self: *const @This(), a: Allocator) void {
        a.free(self.windows);
        a.free(self.x_by);
        a.free(self.y_by);
    }
};

pub const Event = union(enum) {
    spawn: Windows,
    close: Windows,
    toggle_border: Windows,
    change_padding: struct { windows: Windows, x_by: f32, y_by: f32 },
    move: struct { windows: Windows, x_by: f32, y_by: f32 },
    // TODO: add the rest of layout related events

    set_default_color: struct { windows: Windows, prev: u32, next: u32 },
    justify: JustifyEvent,

    add_connection: *Connection,
    hide_connection: *Connection,
    swap_selected_connection_points: *Connection,
    set_connection_arrowhead: struct { conn: *Connection, prev: u32, next: u32 },
};

pub fn deinit(self: *@This()) void {
    while (self.events.len > 0) {
        const ev = self.events.pop() orelse break;
        cleanUpEvent(self.a, ev);
    }
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

pub fn addSpawnEvent(self: *@This(), a: Allocator, windows: Windows) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .spawn = try self.a.dupe(*Window, windows) });
}

pub fn addCloseEvent(self: *@This(), a: Allocator, windows: Windows) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .close = try self.a.dupe(*Window, windows) });
}

pub fn addToggleBorderEvent(self: *@This(), a: Allocator, windows: Windows) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .toggle_border = try self.a.dupe(*Window, windows) });
}

pub fn addChangePaddingEvent(self: *@This(), a: Allocator, windows: Windows, x_by: f32, y_by: f32) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .change_padding = .{
        .windows = try self.a.dupe(*Window, windows),
        .x_by = x_by,
        .y_by = y_by,
    } });
}

pub fn addMoveEvent(self: *@This(), a: Allocator, windows: Windows, x_by: f32, y_by: f32) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .move = .{
        .windows = try self.a.dupe(*Window, windows),
        .x_by = x_by,
        .y_by = y_by,
    } });
}

pub fn addSetDefaultColorEvent(self: *@This(), a: Allocator, windows: Windows, prev: u32, next: u32) !AddNewEventResult {
    return try self.addNewEvent(a, .{
        .set_default_color = .{ .windows = try self.a.dupe(*Window, windows), .prev = prev, .next = next },
    });
}

pub fn addJustifyEvent(self: *@This(), a: Allocator, je: JustifyEvent) !AddNewEventResult {
    return try self.addNewEvent(a, .{ .justify = je });
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
            defer cleanUpEvent(self.a, old_event);

            try self.handleChopAndOvercap(a, &windows_to_cleanup, &connections_to_cleanup, old_event, new_event);
        }
    }

    ///////////////////////////// if reached max capacity, remove first history in the list

    if (self.events.len + 1 >= self.capacity) {
        overcap = true;
        const old_event = self.events.get(0);

        try self.handleChopAndOvercap(a, &windows_to_cleanup, &connections_to_cleanup, old_event, new_event);
        cleanUpEvent(self.a, old_event);

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
    const windows = getWindowsFromEvent(ev) orelse return;

    for (windows) |win| {
        if (!self.wmap.contains(win)) {
            try self.wmap.put(self.a, win, 1);
            continue;
        }

        const count = self.wmap.getPtr(win) orelse continue;
        count.* += 1;
    }
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

    const old_windows = getWindowsFromEvent(old_event) orelse unreachable;
    assert(self.wmapContainsAllWindows(old_windows));

    const may_new_windows = getWindowsFromEvent(new_event);
    if (may_new_windows == null or !std.mem.eql(*Window, old_windows, may_new_windows.?)) {
        for (old_windows) |window| {
            const count = self.wmap.getPtr(window) orelse unreachable;
            assert(count.* > 0);

            if (count.* == 1) {
                try windows_to_cleanup.append(a, window);
                count.* -= 1;
                assert(self.wmap.swapRemove(window));
            }
        }
    }
}

fn wmapContainsAllWindows(self: *@This(), slice: Windows) bool {
    for (slice) |window| assert(self.wmap.contains(window));
    return true;
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

fn cleanUpEvent(a: Allocator, ev: Event) void {
    switch (ev) {
        .justify => |payload| payload.free(a),
        else => if (getWindowsFromEvent(ev)) |windows| a.free(windows),
    }
}

pub fn getWindowsFromEvent(ev: Event) ?Windows {
    return switch (ev) {
        .spawn, .close, .toggle_border => |windows| windows,
        .change_padding => |info| info.windows,
        .move => |info| info.windows,
        .justify => |info| info.windows,
        .set_default_color => |info| info.windows,
        else => null,
    };
}
