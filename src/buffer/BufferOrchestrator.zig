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

const Orchestrator = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;
const idc_if_it_leaks = std.heap.page_allocator;

const Buffer = @import("NeoBuffer.zig");
const rcr = Buffer.rcr;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
strmap: std.AutoArrayHashMapUnmanaged(*Buffer, std.ArrayListUnmanaged([]const u8)) = .{},
pending: ?PendingEdit = null,

pub fn deinit(self: *@This()) void {
    var iter = self.strmap.iterator();
    while (iter.next()) |entry| {
        const buf = entry.key_ptr.*;
        defer buf.destroy(self.a);

        var list = entry.value_ptr;
        defer list.deinit(self.a);
        for (list.items) |str| self.a.free(str);
    }
    self.strmap.deinit(self.a);

    if (self.pending) |*pending| pending.deinit(self.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn createBufferFromFile(self: *@This(), path: []const u8) !*Buffer {
    const allocated_str, const root = try rcr.Node.fromFile(self.a, self.a, path);
    return self.createBuffer(allocated_str, root);
}

pub fn createBufferFromString(self: *@This(), str: []const u8) !*Buffer {
    const allocated_str, const root = try rcr.Node.fromString(self.a, self.a, str);
    return self.createBuffer(allocated_str, root);
}

fn createBuffer(self: *@This(), allocated_str: []const u8, root: rcr.RcNode) !*Buffer {
    const buf = try Buffer.create(self.a, root);
    try self.addBuffer(buf, allocated_str);
    return buf;
}

test createBuffer {
    const a = std.testing.allocator;
    var orchestrator = Orchestrator{ .a = a };
    defer orchestrator.deinit();

    const buf = try orchestrator.createBufferFromString("hello world");
    try eq(1, orchestrator.strmap.get(buf).?.items.len);
    try eqStr("hello world", try buf.toString(std.heap.page_allocator, .lf));
}

/////////////////////////////////////////////////////////////////////////////////////////////

pub fn addBuffer(self: *@This(), buf: *Buffer, allocated_str: []const u8) !void {
    try self.strmap.put(self.a, buf, try std.ArrayListUnmanaged([]const u8).initCapacity(self.a, 1));
    var list = self.strmap.getPtr(buf) orelse unreachable;
    try list.append(self.a, allocated_str);
}

pub fn removeBuffer(self: *@This(), buf: *Buffer) !void {
    assert(self.strmap.contains(buf));
    var list = self.strmap.get(buf) orelse return;
    defer list.deinit(self.a);
    for (list.items) |str| self.a.free(str);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const PendingEdit = struct {
    a: Allocator,
    buf: *Buffer,

    first_cursor_current_byte: u32 = undefined,
    initial_byte_ranges: []const ByteRange = undefined,
    inserted_string: []const u8 = "",

    initial_root: rcr.RcNode,
    roots: std.ArrayListUnmanaged(rcr.RcNode) = .{},
    strlist: std.ArrayListUnmanaged([]const u8) = .{},

    fn init(a: Allocator, buf: *Buffer, cursor_byte_range_iter: anytype) !PendingEdit {
        var ev = PendingEdit{
            .a = a,
            .buf = buf,
            .initial_root = buf.getCurrentRoot(),
        };
        ev.initial_byte_offsets = try a.alloc(u32, cursor_byte_range_iter.len);

        var i: usize = 0;
        while (cursor_byte_range_iter.next()) |byte_range| {
            defer i += 1;
            if (i == 0) ev.first_cursor_current_byte = byte_range.start;
            ev.initial_byte_ranges[i] = byte_range;
        }

        return ev;
    }

    fn deinit(self: *@This()) void {
        self.a.free(self.initial_byte_offsets);
        rcr.freeRcNodes(self.a, self.roots.items);
        self.roots.deinit(self.a);
    }

    fn clear(self: *@This()) !void {

        // TODO: deal with shifting byte offsets in multi cursor edits

        for (self.initial_byte_ranges) |byte_range| {
            const latest_root = self.getLatestRoot();
            const start_line, const start_col = try rcr.getPositionFromByteOffset(latest_root, byte_range.start);
            const end_line, const end_col = try rcr.getPositionFromByteOffset(latest_root, byte_range.end);
            const new_root = try rcr.deleteRange(
                latest_root,
                self.a,
                .{ .line = start_line, .col = start_col },
                .{ .line = end_line, .col = end_col },
            );
            self.roots.append(self.a, new_root);
        }
    }

    fn insertChars(self: *@This(), chars: []const u8, cursor_edit_point_iter: anytype) !void {
        assert(cursor_edit_point_iter.len == self.initial_byte_ranges.len);
        if (cursor_edit_point_iter.len != self.initial_byte_ranges.len) unreachable;

        // update PendingEdit state
        self.first_cursor_current_byte += chars.len;

        const new_str = try std.fmt.allocPrint(self.a, "{s}{s}", .{ self.inserted_string, chars });
        self.a.free(self.inserted_string);
        self.inserted_string = new_str;

        // call `rcr.insertChars()`
        const allocated_str = try self.allocateCharsIfNeeded(chars) orelse return;
        while (cursor_edit_point_iter.next()) |point| {
            const result = try rcr.insertChars(self.getLatestRoot(), self.a, allocated_str, point);
            try self.pending.roots.append(self.a, result.node);
        }
    }

    fn deleteCharsAtTheEnd(self: *@This(), number_of_chars_to_delete: u32, cursor_edit_point_iter: anytype) !void {
        // TODO: deal with shifting byte offsets in multi cursor edits

        assert(cursor_edit_point_iter.len == self.initial_byte_ranges.len);
        if (cursor_edit_point_iter.len != self.initial_byte_ranges.len) unreachable;

        // update PendingEdit state
        var number_of_bytes_to_delete: u32 = 0;
        var i: u32 = 0;
        var backwards_char_iter = try rcr.CharacterBackwardsIterator.init(self.getLatestRoot(), self.first_cursor_current_byte);
        while (backwards_char_iter.prev()) |cp| {
            defer i += 1;
            if (i == number_of_chars_to_delete) break;
            number_of_bytes_to_delete += cp.len;
        }

        assert(number_of_bytes_to_delete <= self.inserted_string.len);
        self.first_cursor_current_byte -= number_of_bytes_to_delete;

        const new_str = try std.fmt.allocPrint(self.a, "{s}", .{self.inserted_string[0 .. self.inserted_string.len - number_of_bytes_to_delete]});
        self.a.free(self.inserted_string);
        self.inserted_string = new_str;

        // call `rcr.deleteChars()`
        while (cursor_edit_point_iter.next()) |point| {
            const result = try rcr.deleteChars(self.getLatestRoot(), self.a, point, number_of_chars_to_delete);
            try self.roots.append(self.a, result.node);
        }
    }

    fn getLatestRoot(self: *const @This()) rcr.RcNode {
        return if (self.roots.items.len > 0) self.roots.getLast() else self.root;
    }

    fn allocateCharsIfNeeded(self: *@This(), chars: []const u8) !?[]const u8 {
        assert(self.pending != null);
        return if (chars.len == 1)
            SINGLE_CHARS[chars[0]]
        else blk: {
            const str = try self.a.dupe(u8, chars);
            try self.strlist.append(self.a, str);
            break :blk str;
        };
    }

    fn check(self: *const @This(), number_of_cursors: u32, first_cursor_byte_offset: u32) bool {
        if (number_of_cursors != self.initial_byte_offsets.len) return false;
        return first_cursor_byte_offset != self.first_cursor_current_byte;
    }
};

pub const ByteRange = struct {
    start: u32,
    end: u32,
};

/////////////////////////////////////////////////////////////////////////////////////////////

pub fn startInsertMode(self: *@This(), buf: *Buffer, cursor_byte_range_iter: anytype) !void {
    assert(self.pending == null);
    self.pending = try PendingEdit.init(self.a, buf, cursor_byte_range_iter);
}

pub fn clear(self: *@This(), buf: *Buffer, cursor_byte_range_iter: anytype) !void {
    try self.startInsertMode(buf, cursor_byte_range_iter);
    self.pending.?.clear();
}

pub fn exitInsertMode(self: *@This()) !void {
    assert(self.pending != null);
    const pending = &(self.pending orelse return);
    pending.deinit();
    self.pending = null;
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
