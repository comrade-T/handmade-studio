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

const InsertManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const assert = std.debug.assert;

const Buffer = @import("NeoBuffer.zig");
const rcr = Buffer.rcr;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
strmap: std.AutoArrayHashMapUnmanaged(*Buffer, std.ArrayListUnmanaged([]const u8)) = .{},
pending: ?PendingEdit = null,

const PendingEdit = struct {
    buf: *Buffer,

    initial_root: rcr.RcNode,
    initial_edit_points: []const rcr.EditPoint,

    roots: std.ArrayListUnmanaged(rcr.RcNode) = .{},

    num_of_strings_allocated: usize = 0,

    fn deinit(self: *@This(), a: Allocator) void {
        a.free(self.initial_edit_points);
        rcr.freeRcNodes(a, self.roots.items);
        self.roots.deinit(self.a);
    }
};

pub fn deinit(self: *@This()) void {
    var iter = self.strmap.iterator();
    while (iter.next()) |entry| {
        var list = entry.value_ptr;
        defer list.deinit(self.a);
        for (list.items) |str| self.a.free(str);
    }

    if (self.pending) |*pending| pending.deinit();
}

//////////////////////////////////////////////////////////////////////////////////////////////

// pub fn createBuffer(self: *@This()) !*Buffer {
//     // TODO:
// }

/////////////////////////////////////////////////////////////////////////////////////////////

pub fn initBuffer(self: *@This(), buf: *Buffer, allocated_str: []const u8) !void {
    try self.strmap.put(self.a, buf, try std.ArrayListUnmanaged([]const u8).initCapacity(self.a, 1));
    var list = self.strmap.get(buf) orelse unreachable;
    try list.append(self.a, allocated_str);
}

pub fn removeBuffer(self: *@This(), buf: *Buffer) !void {
    assert(self.strmap.contains(buf));
    var list = self.strmap.get(buf) orelse return;
    defer list.deinit(self.a);
    for (list.items) |str| self.a.free(str);
}

/////////////////////////////////////////////////////////////////////////////////////////////

pub fn startInsertMode(self: *@This(), buf: *Buffer, initial_edit_points: []const rcr.EditPoint) !void {
    assert(self.num_of_strings_to_clean_up == 0);
    self.pending = PendingEdit{
        .buf = buf,
        .initial_root = buf.getCurrentRoot(),
        .initial_edit_points = try self.a.dupe(rcr.EditPoint, initial_edit_points),
    };
}

pub fn exitInsertMode(self: *@This()) !void {
    assert(self.pending != null);
    const pending = &(self.pending orelse return);
    defer {
        pending.deinit();
        self.pending = null;
    }

    // TODO:
}

pub fn insertChars(self: *@This(), chars: []const u8, cursor_iter: anytype) !void {
    assert(self.pending != null);
    const pending = &(self.pending orelse return);

    const allocated_str = try self.allocateCharsIfNeeded(chars) orelse return;
    var latest_root = if (pending.roots.items.len > 0)
        pending.roots.getLast()
    else
        pending.root orelse return;

    while (cursor_iter.next()) |point| {
        const result = try rcr.insertChars(latest_root, self.a, allocated_str, point);
        latest_root = result.node;
        try self.pending.roots.append(self.a, latest_root);
    }
}

fn allocateCharsIfNeeded(self: *@This(), chars: []const u8) !?[]const u8 {
    assert(self.pending != null);
    return if (chars.len == 1)
        SINGLE_CHARS[chars[0]]
    else blk: {
        const str = try self.a.dupe(u8, chars);
        var list = self.strmap.get(self.pending.?.buf) orelse unreachable;
        try list.append(self.a, str);
        self.pending.?.num_of_strings_allocated += 1;
        break :blk str;
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const MockPointsIterator = struct {
    points: []const rcr.EditPoint,
    index: usize,

    fn next(self: *@This()) ?Buffer.rcr.EditPoint {
        defer self.index += 1;
        if (self.index >= self.points.len) return null;
        return self.points[self.index];
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

const SINGLE_CHARS = [_][]const u8{
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 0-15
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 16-31
    " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/", // 32-47
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?", // 48-63
    "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", // 64-79
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", // 80-95
    "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", // 96-111
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "", // 112-127
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 128-143
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 144-159
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 160-175
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 176-191
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 192-207
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 208-223
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 224-239
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 240-255
};
