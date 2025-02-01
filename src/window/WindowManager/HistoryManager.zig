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

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
capacity: usize,
index: i64 = -1,
events: std.MultiArrayList(Event) = .{},
wmap: std.AutoHashMapUnmanaged(*Window, usize) = .{},

pub const Event = union(enum) {
    spawn: *Window,
    close: *Window,
    toggle_border: *Window,
    change_padding: struct { win: *Window, x_by: f32, y_by: f32 },
    move: struct { win: *Window, x_by: f32, y_by: f32 },
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

pub fn undo(self: *@This()) ?Event {
    if (self.index <= -1 or self.events.len == 0) return null;
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

const WindowsToCleanUp = []*Window;

pub fn addSpawnEvent(self: *@This(), a: Allocator, win: *Window) !WindowsToCleanUp {
    return try self.addNewEvent(a, .{ .spawn = win });
}

pub fn addCloseEvent(self: *@This(), a: Allocator, win: *Window) !WindowsToCleanUp {
    return try self.addNewEvent(a, .{ .close = win });
}

pub fn addToggleBorderEvent(self: *@This(), a: Allocator, win: *Window) !WindowsToCleanUp {
    return try self.addNewEvent(a, .{ .toggle_border = win });
}

pub fn addChangePaddingEvent(self: *@This(), a: Allocator, win: *Window, x_by: f32, y_by: f32) !WindowsToCleanUp {
    return try self.addNewEvent(a, .{ .change_padding = .{ .win = win, .x_by = x_by, .y_by = y_by } });
}

pub fn addMoveEvent(self: *@This(), a: Allocator, win: *Window, x_by: f32, y_by: f32) !WindowsToCleanUp {
    return try self.addNewEvent(a, .{ .move = .{ .win = win, .x_by = x_by, .y_by = y_by } });
}

////////////////////////////////////////////////////////////////////////////////////////////// internal

fn addNewEvent(self: *@This(), a: Allocator, event: Event) !WindowsToCleanUp {
    assert(self.capacity > 0);
    assert(self.index == 0 or self.index < self.events.len);
    assert(self.events.len <= self.capacity);

    var list = std.ArrayListUnmanaged(*Window){};
    var overcap = false;

    ///////////////////////////// if the needle (index) is in the middle, chop off the rest of the history

    if (self.events.len > 1 and self.index < self.events.len - 1) {
        var i: usize = self.events.len;
        while (i > self.index + 1) {
            defer i -= 1;
            const ev = self.events.pop();
            try self.removeEventFromWindowMapAndUpdateTheCleanUpList(a, &list, ev);
        }
    }

    ///////////////////////////// if reached max capacity, remove first history in the list

    if (self.events.len + 1 > self.capacity) {
        overcap = true;
        const ev = self.events.get(0);

        try self.removeEventFromWindowMapAndUpdateTheCleanUpList(a, &list, ev);
        self.events.orderedRemove(0);
    }

    /////////////////////////////

    if (!overcap) self.index += 1;
    assert(self.index < self.capacity - 1);

    try self.events.append(self.a, event);
    try self.addEventToWindowMap(event);

    return list.toOwnedSlice(a);
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

fn removeEventFromWindowMapAndUpdateTheCleanUpList(
    self: *@This(),
    a: Allocator,
    list: *std.ArrayListUnmanaged(*Window),
    ev: Event,
) !void {
    const win = getWindowFromEvent(ev) orelse return;
    assert(self.wmap.contains(win));

    const count = self.wmap.getPtr(win) orelse return;
    assert(count.* > 0);

    if (count.* == 1) {
        try list.append(a, win);
        const removed = self.wmap.remove(win);
        assert(removed);
        return;
    }
    count.* -= 1;
}

fn getWindowFromEvent(ev: Event) ?*Window {
    return switch (ev) {
        .spawn => |win| win,
        .close => |win| win,
        .toggle_border => |win| win,
        .change_padding => |info| info.win,
        .move => |info| info.win,
    };
}
