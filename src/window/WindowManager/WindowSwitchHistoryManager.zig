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

const WindowSwitchHistorymanager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const WindowManager = @import("../WindowManager.zig");
const Window = WindowManager.Window;

wm: *WindowManager,
capacity: u8 = 100,
index: i64 = -1,
events: std.ArrayListUnmanaged(Event) = .{},

const Event = struct { from: ?*Window, to: ?*Window };

pub fn deinit(self: *@This()) void {
    self.events.deinit(self.wm.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn addNewEvent(self: *@This(), new_event: Event) !void {
    if (self.events.items.len > 0 and self.index <= self.events.items.len - 1) {
        var i: usize = self.events.items.len;
        while (i > self.index + 1) {
            defer i -= 1;
            _ = self.events.pop() orelse break;
        }
    }

    var overcap = false;
    if (self.events.items.len + 1 >= self.capacity) {
        overcap = true;
        _ = self.events.orderedRemove(0);
    }

    if (!overcap) self.index += 1;
    try self.events.append(self.wm.a, new_event);
}

pub fn undo(self: *@This()) ?*Window {
    if (self.index < 0 or self.events.items.len == 0) return null;
    defer self.index -= 1;
    return self.events.items[@intCast(self.index)].from;
}

pub fn redo(self: *@This()) ?*Window {
    if (self.events.items.len == 0) return null;
    if (self.index + 1 < self.events.items.len) {
        self.index += 1;
        return self.events.items[@intCast(self.index)].to;
    }
    return null;
}

pub fn reset(self: *@This()) void {
    self.index = -1;
    self.events.clearRetainingCapacity();
}

pub fn purgeWindow(self: *@This(), target: *Window) void {
    var i: usize = self.events.items.len;
    while (i > 0) {
        i -= 1;
        const ev = self.events.items[i];
        if (target == ev.from or target == ev.to) _ = self.events.swapRemove(i);
    }
}
