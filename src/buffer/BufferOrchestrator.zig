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

    if (self.pending) |*pending| pending.deinit();
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
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
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
    first_cursor_lowest_byte: u32 = undefined,
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
        var initial_byte_ranges = try a.alloc(ByteRange, cursor_byte_range_iter.len());

        var i: usize = 0;
        while (cursor_byte_range_iter.next()) |byte_range| {
            defer i += 1;
            if (i == 0) {
                ev.first_cursor_current_byte = byte_range.start;
                ev.first_cursor_lowest_byte = byte_range.start;
            }
            initial_byte_ranges[i] = byte_range;
        }

        ev.initial_byte_ranges = initial_byte_ranges;
        return ev;
    }

    fn deinit(self: *@This()) void {
        self.a.free(self.initial_byte_ranges);
        rcr.freeRcNodes(self.a, self.roots.items);
        for (self.strlist.items) |str| self.a.free(str);
        self.strlist.deinit(self.a);
        self.roots.deinit(self.a);
        if (self.inserted_string.len > 0) self.a.free(self.inserted_string);
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
        assert(cursor_edit_point_iter.len() == self.initial_byte_ranges.len);

        // update PendingEdit state
        self.first_cursor_current_byte += @intCast(chars.len);

        const new_str = try std.fmt.allocPrint(self.a, "{s}{s}", .{ self.inserted_string, chars });
        self.a.free(self.inserted_string);
        self.inserted_string = new_str;

        // call `rcr.insertChars()`
        const allocated_str = try self.allocateCharsIfNeeded(chars) orelse return;
        while (cursor_edit_point_iter.next()) |point| {

            // TODO: deal with shifting byte offsets in multi cursor edits

            const result = try rcr.insertChars(self.getLatestRoot(), self.a, allocated_str, point);
            try self.roots.append(self.a, result.node);
        }
    }

    fn deleteCharsAtTheEnd(self: *@This(), number_of_chars_to_delete: u32, cursor_edit_point_iter: anytype) !void {
        assert(cursor_edit_point_iter.len == self.initial_byte_ranges.len);

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
        self.first_cursor_lowest_byte = @min(self.first_cursor_lowest_byte, self.first_cursor_current_byte);

        const new_str = try std.fmt.allocPrint(self.a, "{s}", .{self.inserted_string[0 .. self.inserted_string.len - number_of_bytes_to_delete]});
        self.a.free(self.inserted_string);
        self.inserted_string = new_str;

        // call `rcr.deleteChars()`
        while (cursor_edit_point_iter.next()) |point| {

            // TODO: deal with shifting byte offsets in multi cursor edits

            const result = try rcr.deleteChars(self.getLatestRoot(), self.a, point, number_of_chars_to_delete);
            try self.roots.append(self.a, result.node);
        }
    }

    fn getLatestRoot(self: *const @This()) rcr.RcNode {
        return if (self.roots.items.len > 0) self.roots.getLast() else self.initial_root;
    }

    fn allocateCharsIfNeeded(self: *@This(), chars: []const u8) !?[]const u8 {
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

    fn finalizeChangesToBuffer(self: *const @This(), orchestrator: *Orchestrator) !void {
        if (self.initial_byte_ranges.len == 0) return;

        const allocated_str = if (self.inserted_string.len > 0) blk: {
            const str = try self.a.dupe(u8, self.inserted_string);
            var list = orchestrator.strmap.getPtr(self.buf) orelse unreachable;
            try list.append(self.a, str);
            break :blk str;
        } else "";

        const official_parent_index = self.buf.index;
        const num_of_bytes_deleted_from_start_anchor = self.initial_byte_ranges[0].start - self.first_cursor_lowest_byte;
        var total_number_of_shifted_bytes: i64 = 0;

        for (self.initial_byte_ranges, 0..) |initial_byte_range, i| {
            const parent_index = if (i == self.initial_byte_ranges.len - 1) official_parent_index else Buffer.NULL_PARENT_INDEX;

            const delete_start_byte_offset = initial_byte_range.start - num_of_bytes_deleted_from_start_anchor;

            var number_of_shifted_bytes: i64 = 0;
            if (i > 0) number_of_shifted_bytes = @as(i64, @intCast(self.inserted_string.len)) + (initial_byte_range.end - delete_start_byte_offset);
            total_number_of_shifted_bytes += @intCast(number_of_shifted_bytes);

            const adjusted_delete_start_byte: i64 = @as(i64, @intCast(delete_start_byte_offset)) + total_number_of_shifted_bytes;
            const delete_start_line, const delete_start_col = try rcr.getPositionFromByteOffset(self.buf.getCurrentRoot(), @intCast(adjusted_delete_start_byte));

            const adjusted_delete_end_byte: i64 = @as(i64, @intCast(initial_byte_range.end)) + total_number_of_shifted_bytes;
            const delete_end_line, const delete_end_col = try rcr.getPositionFromByteOffset(self.buf.getCurrentRoot(), @intCast(adjusted_delete_end_byte));

            const edit_request = Buffer.AddEditRequest{
                .parent_index = parent_index,
                .chars = allocated_str,

                .old_start_byte = initial_byte_range.start,
                .old_end_byte = initial_byte_range.end,
                .new_start_byte = @intCast(@as(i64, @intCast(delete_start_byte_offset)) + total_number_of_shifted_bytes),
                .new_end_byte = @intCast(@as(i64, @intCast(delete_start_byte_offset + self.inserted_string.len)) + total_number_of_shifted_bytes),

                .delete_start_line = delete_start_line,
                .delete_start_col = delete_start_col,
                .delete_end_line = delete_end_line,
                .delete_end_col = delete_end_col,
            };

            try self.buf.addEdit(self.a, edit_request);
        }
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

pub fn insertChars(self: *@This(), chars: []const u8, cursor_edit_point_iter: anytype) !void {
    assert(self.pending != null);
    try self.pending.?.insertChars(chars, cursor_edit_point_iter);
}

test insertChars {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();
    const buf = try orchestrator.createBufferFromString("hello world");

    var byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
    try orchestrator.startInsertMode(buf, &byte_range_iter);
    {
        var edit_points_iter = MockIterator(rcr.EditPoint){ .items = &.{.{ .line = 0, .col = 0 }} };
        try orchestrator.insertChars("// ", &edit_points_iter);
    }
    try orchestrator.exitInsertMode();

    try eqStr("// hello world", try buf.toString(std.heap.page_allocator, .lf));
}

pub fn clear(self: *@This(), buf: *Buffer, cursor_byte_range_iter: anytype) !void {
    try self.startInsertMode(buf, cursor_byte_range_iter);
    try self.pending.?.clear();
}

pub fn exitInsertMode(self: *@This()) !void {
    assert(self.pending != null);
    try self.pending.?.finalizeChangesToBuffer(self);
    self.pending.?.deinit();
    self.pending = null;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn MockIterator(T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,

        fn next(self: *@This()) ?T {
            defer self.index += 1;
            if (self.index >= self.items.len) return null;
            return self.items[self.index];
        }

        fn len(self: *const @This()) usize {
            return self.items.len;
        }
    };
}

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

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(Buffer);
}
