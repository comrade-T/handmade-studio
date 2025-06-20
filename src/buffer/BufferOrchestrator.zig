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

pub const Buffer = @import("NeoBuffer.zig");
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

fn addBuffer(self: *@This(), buf: *Buffer, allocated_str: []const u8) !void {
    try self.strmap.put(self.a, buf, try std.ArrayListUnmanaged([]const u8).initCapacity(self.a, 1));
    var list = self.strmap.getPtr(buf) orelse unreachable;
    try list.append(self.a, allocated_str);
}

pub fn removeBuffer(self: *@This(), buf: *Buffer) void {
    assert(self.strmap.contains(buf));
    assert(self.pending == null);

    var list = self.strmap.get(buf) orelse return;
    defer list.deinit(self.a);
    for (list.items) |str| self.a.free(str);

    assert(self.strmap.swapRemove(buf));
    defer buf.destroy(self.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const PendingEdit = struct {
    a: Allocator,
    buf: *Buffer,

    shifted_bytes_total: i64 = 0,
    trackers: []Tracker = undefined,
    should_create_new_pending_edit: bool = false,

    inserted_string: InsertedString = .{},

    initial_root: rcr.RcNode,
    roots: std.ArrayListUnmanaged(rcr.RcNode) = .{},
    strlist: std.ArrayListUnmanaged([]const u8) = .{},

    fn init(a: Allocator, buf: *Buffer, cursor_byte_range_iter: anytype) !PendingEdit {
        var ev = PendingEdit{
            .a = a,
            .buf = buf,
            .initial_root = buf.getCurrentRoot(),
        };
        ev.trackers = try a.alloc(Tracker, cursor_byte_range_iter.len());

        var i: usize = 0;
        while (cursor_byte_range_iter.next()) |byte_range| {
            defer i += 1;
            ev.trackers[i] = Tracker{
                .initial = byte_range,
                .current = byte_range.start,
                .lowest = byte_range.start,
                .cursor = byte_range.start,
            };
        }

        return ev;
    }

    fn deinit(self: *@This()) void {
        rcr.freeRcNodes(self.a, self.roots.items);
        self.roots.deinit(self.a);

        for (self.strlist.items) |str| self.a.free(str);
        self.strlist.deinit(self.a);

        self.a.free(self.trackers);

        self.inserted_string.deinit(self.a);
    }

    fn clear(self: *@This()) !void {
        defer self.resetShiftedBytesTotal();
        for (self.trackers) |*tracker| try tracker.clear(self);
    }

    fn insertChars(self: *@This(), chars: []const u8, cursor_byte_range_iter: anytype) !void {
        defer self.resetShiftedBytesTotal();
        const allocated_str = try self.allocateCharsIfNeeded(chars);
        try self.inserted_string.insertChars(self.a, allocated_str);
        for (self.trackers) |*tracker| {
            const byte_range = cursor_byte_range_iter.next() orelse unreachable;
            try tracker.insertChars(self, byte_range, allocated_str);
        }
    }

    fn deleteChars(self: *@This(), number_of_chars_to_delete: u32, cursor_byte_range_iter: anytype) !void {
        defer self.resetShiftedBytesTotal();
        var number_of_bytes_to_trim_off: u32 = 0;
        for (self.trackers, 0..) |*tracker, i| {
            const byte_range = cursor_byte_range_iter.next() orelse unreachable;
            const trimmed = try tracker.deleteChars(self, byte_range, number_of_chars_to_delete);
            if (i == 0) number_of_bytes_to_trim_off = trimmed;
        }
        try self.inserted_string.deleteChars(self.a, number_of_bytes_to_trim_off);
    }

    fn finalizeChangesToBuffer(self: *@This(), orchestrator: *Orchestrator) !void {
        assert(self.shifted_bytes_total == 0);

        const allocated_str = if (self.inserted_string.buf.len > 0) blk: {
            const str = try self.a.dupe(u8, self.inserted_string.buf);
            var list = orchestrator.strmap.getPtr(self.buf) orelse unreachable;
            try list.append(self.a, str);
            break :blk str;
        } else "";

        const non_null_parent_index = self.buf.index;
        for (self.trackers, 0..) |*tracker, i| {
            const shifted_bytes: i64 =
                @as(i64, @intCast(tracker.initial.end - tracker.initial.start)) -
                @as(i64, @intCast(tracker.initial.end - tracker.lowest)) +
                @as(i64, @intCast(allocated_str.len));
            defer self.shifted_bytes_total += shifted_bytes;

            const adjusted_delete_start_byte: i64 = @as(i64, @intCast(tracker.lowest)) + self.shifted_bytes_total;
            const delete_start_line, const delete_start_col = try rcr.getPositionFromByteOffset(self.buf.getCurrentRoot(), @intCast(adjusted_delete_start_byte));

            const adjusted_delete_end_byte: i64 = @as(i64, @intCast(tracker.initial.end)) + self.shifted_bytes_total;
            const delete_end_line, const delete_end_col = try rcr.getPositionFromByteOffset(self.buf.getCurrentRoot(), @intCast(adjusted_delete_end_byte));

            const req = Buffer.AddEditRequest{
                .parent_index = if (i == self.trackers.len - 1) non_null_parent_index else Buffer.NULL_PARENT_INDEX,
                .chars = allocated_str,

                .old_start_byte = tracker.initial.start,
                .old_end_byte = tracker.initial.end,

                .new_start_byte = @intCast(tracker.lowest + self.shifted_bytes_total),
                .new_end_byte = @intCast(tracker.current + self.shifted_bytes_total),

                .delete_start_line = delete_start_line,
                .delete_start_col = delete_start_col,
                .delete_end_line = delete_end_line,
                .delete_end_col = delete_end_col,
            };

            const has_no_changes = req.old_start_byte == req.new_start_byte and req.old_end_byte == req.new_end_byte;
            if (has_no_changes) continue;
            try self.buf.addEdit(self.a, req);
        }
    }

    const Tracker = struct {
        initial: ByteRange,
        current: u32,
        lowest: u32,
        cursor: u32,

        fn clear(self: *@This(), pe: *PendingEdit) !void {
            const number_of_deleted_bytes = self.initial.end - self.initial.start;
            defer pe.shifted_bytes_total -= number_of_deleted_bytes;

            self.cursor = @intCast(@as(i64, @intCast(self.cursor)) + pe.shifted_bytes_total);
            self.current = self.cursor;
            self.lowest = self.cursor;
            self.initial = ByteRange{
                .start = self.cursor,
                .end = self.cursor + number_of_deleted_bytes,
            };

            const start_line, const start_col = try rcr.getPositionFromByteOffset(pe.getLatestRoot(), self.initial.start);
            const end_line, const end_col = try rcr.getPositionFromByteOffset(pe.getLatestRoot(), self.initial.end);

            const new_root = try rcr.deleteRange(
                pe.getLatestRoot(),
                pe.a,
                .{ .line = start_line, .col = start_col },
                .{ .line = end_line, .col = end_col },
            );
            try pe.roots.append(pe.a, new_root);
        }

        fn insertChars(self: *@This(), pe: *PendingEdit, current_cursor_byte_range: ByteRange, allocated_str: []const u8) !void {
            self.current += @intCast(allocated_str.len);

            self.cursor = @intCast(@as(i64, @intCast(self.cursor)) + @as(i64, @intCast(allocated_str.len)) + pe.shifted_bytes_total);

            defer pe.shifted_bytes_total += @intCast(allocated_str.len);

            const adjusted_byte_offset: i64 = @as(i64, @intCast(current_cursor_byte_range.start)) + pe.shifted_bytes_total;
            const line, const col = try rcr.getPositionFromByteOffset(pe.getLatestRoot(), @intCast(adjusted_byte_offset));

            const result = try rcr.insertChars(pe.getLatestRoot(), pe.a, allocated_str, .{ .line = line, .col = col });
            try pe.roots.append(pe.a, result.node);
        }

        fn deleteChars(self: *@This(), pe: *PendingEdit, current_cursor_byte_range: ByteRange, chars_to_delete: u32) !u32 {
            const shifted_start_byte = current_cursor_byte_range.start + pe.shifted_bytes_total;
            var bytes_can_delete: u32 = 0;
            var chars_can_delete: u32 = 0;
            var backwards_char_iter = try rcr.CharacterBackwardsIterator.init(pe.getLatestRoot().value, @intCast(shifted_start_byte));
            while (backwards_char_iter.prev()) |cp| {
                if (chars_can_delete == chars_to_delete) break;
                bytes_can_delete += cp.len;
                chars_can_delete += 1;
            }

            self.current -= bytes_can_delete;
            self.lowest = @min(self.lowest, self.current);

            self.cursor = @intCast(@as(i64, @intCast(self.cursor)) - @as(i64, @intCast(bytes_can_delete)) + pe.shifted_bytes_total);

            defer pe.shifted_bytes_total -= bytes_can_delete;

            if (chars_can_delete != chars_to_delete) pe.should_create_new_pending_edit = true;

            if (chars_can_delete == 0) return bytes_can_delete;

            const delete_start = shifted_start_byte - bytes_can_delete;
            const line, const col = try rcr.getPositionFromByteOffset(pe.getLatestRoot(), @intCast(delete_start));
            const new_root = try rcr.deleteChars(pe.getLatestRoot(), pe.a, .{ .line = line, .col = col }, chars_can_delete);
            try pe.roots.append(pe.a, new_root);

            return bytes_can_delete;
        }
    };

    const InsertedString = struct {
        buf: []const u8 = "",

        fn insertChars(self: *@This(), a: Allocator, chars: []const u8) !void {
            const new_str = try std.fmt.allocPrint(a, "{s}{s}", .{ self.buf, chars });
            a.free(self.buf);
            self.buf = new_str;
        }

        fn deleteChars(self: *@This(), a: Allocator, number_of_bytes_to_trim_off: u32) !void {
            const end = self.buf.len - @min(self.buf.len, number_of_bytes_to_trim_off);
            const new_str = try std.fmt.allocPrint(a, "{s}", .{self.buf[0..end]});
            a.free(self.buf);
            self.buf = new_str;
        }

        fn deinit(self: *@This(), a: Allocator) void {
            if (self.buf.len > 0) a.free(self.buf);
        }
    };

    pub fn getLatestRoot(self: *const @This()) rcr.RcNode {
        return self.roots.getLastOrNull() orelse self.initial_root;
    }

    fn resetShiftedBytesTotal(self: *@This()) void {
        self.shifted_bytes_total = 0;
    }

    fn allocateCharsIfNeeded(self: *@This(), chars: []const u8) ![]const u8 {
        return if (chars.len == 1)
            SINGLE_CHARS[chars[0]]
        else blk: {
            const str = try self.a.dupe(u8, chars);
            try self.strlist.append(self.a, str);
            break :blk str;
        };
    }

    fn shouldCreateNewPendingEvent(self: *const @This(), cursor_byte_range_iter: anytype) bool {
        if (self.should_create_new_pending_edit) return true;
        if (cursor_byte_range_iter.len() != self.trackers.len) return true;
        return cursor_byte_range_iter.first().start != self.trackers[0].current;
    }
};

pub const ByteRange = struct {
    start: u32,
    end: u32,
};

/////////////////////////////////////////////////////////////////////////////////////////////

pub fn startEditing(self: *@This(), buf: *Buffer, cursor_byte_range_iter: anytype) !void {
    assert(self.pending == null);
    self.pending = try PendingEdit.init(self.a, buf, cursor_byte_range_iter);
}

pub fn insertChars(self: *@This(), chars: []const u8, cursor_byte_range_iter: anytype) !void {
    assert(self.pending != null);
    try self.handlePotentialNewPendingEvent(cursor_byte_range_iter);
    try self.pending.?.insertChars(chars, cursor_byte_range_iter);
}

test insertChars {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();

    ///////////////////////////// Single Cursor

    { // insert 1 single multi-bytes string at the beginning of the Buffer
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("// ", &edit_byte_range_iter);
            try eqStr("// hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("// hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }
    { // insert multiple single-byte strings
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("/", &edit_byte_range_iter);
            try eqStr("/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
            try orchestrator.insertChars("/", &edit_byte_range_iter);
            try eqStr("//hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
            try orchestrator.insertChars(" ", &edit_byte_range_iter);
            try eqStr("// hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("// hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
    }
    { // insert 1 single-byte string in the middle of the Buffer
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.insertChars(",", &edit_byte_range_iter);
            try eqStr("hello, world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hello, world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
    }
    { // insert 1 single-byte string in the middle of the Buffer, then insert 1 multi-bytes string to the start of the Buffer
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        {
            var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.startEditing(buf, &initial_byte_range_iter);
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
                try orchestrator.insertChars(",", &edit_byte_range_iter);
                try eqStr("hello, world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            try orchestrator.stopEditing();

            try eqStr("hello, world", try buf.toString(std.heap.page_allocator, .lf));
            try eq(2, buf.edits.items.len);
        }

        {
            var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.startEditing(buf, &initial_byte_range_iter);
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
                try orchestrator.insertChars("/", &edit_byte_range_iter);
                try eqStr("/hello, world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
                try orchestrator.insertChars("/", &edit_byte_range_iter);
                try eqStr("//hello, world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
                try orchestrator.insertChars(" ", &edit_byte_range_iter);
                try eqStr("// hello, world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            try orchestrator.stopEditing();

            try eqStr("// hello, world", try buf.toString(std.heap.page_allocator, .lf));
            try eq(3, buf.edits.items.len);
        }

        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }

    ///////////////////////////// Multi Cursor

    { // using 2 cursors, insert 1 single-byte string at the beginning and middle of the Buffer
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 0, .end = 0 },
            .{ .start = 5, .end = 5 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 0, .end = 0 },
                .{ .start = 5, .end = 5 },
            } };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|hello| world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("|hello| world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }

    { // using 2 cursors, insert 1 single-byte string at the beginning and middle of the Buffer 2 times
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        {
            var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 0, .end = 0 },
                .{ .start = 5, .end = 5 },
            } };
            try orchestrator.startEditing(buf, &initial_byte_range_iter);
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                    .{ .start = 0, .end = 0 },
                    .{ .start = 5, .end = 5 },
                } };
                try orchestrator.insertChars("(", &edit_byte_range_iter);
                try eqStr("(hello( world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            {
                var edit_byte_range_iter = MockIterator(ByteRange){
                    .items = &.{
                        .{ .start = 1, .end = 1 },
                        .{ .start = 7, .end = 7 },
                    },
                };
                try orchestrator.insertChars(")", &edit_byte_range_iter);
                try eqStr("()hello() world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
            }
            try orchestrator.stopEditing();
        }

        try eqStr("()hello() world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }

    ///////////////////////////// Handling Nexus Events

    { // 1 cursor, insert '/' -> nexus insert '|'
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("/", &edit_byte_range_iter);
            try eqStr("/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        { // nexus
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("|/hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }

    { // 1 cursor, insert '/' -> nexus insert '|' continued with 'x' continued with '|'
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("/", &edit_byte_range_iter);
            try eqStr("/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        { // nexus
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
            try orchestrator.insertChars("x", &edit_byte_range_iter);
            try eqStr("|x/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|x|/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("|x|/hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }

    { // 1 cursor, insert '/' continued with ' ' -> nexus insert '|' continued with 'x' continued with '|'
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("/", &edit_byte_range_iter);
            try eqStr("/hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
            try orchestrator.insertChars(" ", &edit_byte_range_iter);
            try eqStr("/ hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        { // nexus
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|/ hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
            try orchestrator.insertChars("x", &edit_byte_range_iter);
            try eqStr("|x/ hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("|x|/ hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("|x|/ hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }
}

pub fn deleteChars(self: *@This(), number_of_chars_to_delete: u32, cursor_byte_range_iter: anytype) !void {
    assert(self.pending != null);
    try self.handlePotentialNewPendingEvent(cursor_byte_range_iter);
    try self.pending.?.deleteChars(number_of_chars_to_delete, cursor_byte_range_iter);
}

test deleteChars {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();

    ///////////////////////////// Single Cursor

    { // delete 1 single char, 1 time
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hell world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    { // delete 1 single char, 4 times
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 4, .end = 4 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hel world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 3, .end = 3 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("he world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("h world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("h world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    ///////////////////////////// Multi Cursor

    { // 2 cursors, each delete 1 char, 1 time
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 2, .end = 2 },
            .{ .start = 8, .end = 8 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 2, .end = 2 },
                .{ .start = 8, .end = 8 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hllo wrld", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hllo wrld", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }

    { // 2 cursors, each delete 1 char, 3 times
        const buf = try orchestrator.createBufferFromString("ABCDE FGHJK");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 3, .end = 3 },
            .{ .start = 9, .end = 9 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 3, .end = 3 },
                .{ .start = 9, .end = 9 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("ABDE FGJK", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 2, .end = 2 },
                .{ .start = 7, .end = 7 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("ADE FJK", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 1, .end = 1 },
                .{ .start = 5, .end = 5 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("DE JK", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("DE JK", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }

    ///////////////////////////// Nexus Events

    { // delete 1 char -> nexus delete 1 char
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        { // nexus
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("ell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("ell world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }

    { // 2 cursors, each delete 1 char, 1 time
        const buf = try orchestrator.createBufferFromString("ABCDE FGHJK");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 2, .end = 2 },
            .{ .start = 8, .end = 8 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        { // results in 'hllo wrld'
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 2, .end = 2 },
                .{ .start = 8, .end = 8 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("ACDE FHJK", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        { // nexus
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 3, .end = 3 },
                .{ .start = 8, .end = 8 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("ACE FHK", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("ACE FHK", try buf.toString(std.heap.page_allocator, .lf));
        try eq(5, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[3].parent_index);
        try eq(2, buf.edits.items[4].parent_index);
    }

    ///////////////////////////// Cursor at line 0 and col 0

    { // 1 cursor
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hello world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hello world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(1, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
    }

    { // 2 cursors, deleting 1 char each
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 0, .end = 0 },
            .{ .start = 5, .end = 5 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 0, .end = 0 },
                .{ .start = 5, .end = 5 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hell world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    { // 2 cursors, deleting multiple chars each, should create Nexus Events
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 0, .end = 0 },
            .{ .start = 5, .end = 5 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 0, .end = 0 },
                .{ .start = 5, .end = 5 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 0, .end = 0 },
                .{ .start = 4, .end = 4 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hel world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("hel world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
        try eq(1, buf.edits.items[2].parent_index);
    }
}

test "insertChars() & deleteChars()" {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();

    { // 1 cursor
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 5, .end = 5 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hell world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 4, .end = 4 }} };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hel world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 3, .end = 3 }} };
            try orchestrator.insertChars("i", &edit_byte_range_iter);
            try eqStr("heli world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 4, .end = 4 }} };
            try orchestrator.insertChars("o", &edit_byte_range_iter);
            try eqStr("helio world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("helio world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    { // 2 cursors
        const buf = try orchestrator.createBufferFromString("helio helio");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 5, .end = 5 },
            .{ .start = 11, .end = 11 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 5, .end = 5 },
                .{ .start = 11, .end = 11 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("heli heli", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 4, .end = 4 },
                .{ .start = 9, .end = 9 },
            } };
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hel hel", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 3, .end = 3 },
                .{ .start = 7, .end = 7 },
            } };
            try orchestrator.insertChars("r", &edit_byte_range_iter);
            try eqStr("helr helr", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{
                .{ .start = 4, .end = 4 },
                .{ .start = 9, .end = 9 },
            } };
            try orchestrator.insertChars("o", &edit_byte_range_iter);
            try eqStr("helro helro", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("helro helro", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }
}

test "PendingEdit's trackers are reliable enough to be used for updating CursorManager" {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();

    { // 2 cursors
        const buf = try orchestrator.createBufferFromString("helio helio");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 5, .end = 5 },
            .{ .start = 11, .end = 11 },
        } };
        try orchestrator.startEditing(buf, &initial_byte_range_iter);
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("heli heli", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.deleteChars(1, &edit_byte_range_iter);
            try eqStr("hel hel", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("r", &edit_byte_range_iter);
            try eqStr("helr helr", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("o", &edit_byte_range_iter);
            try eqStr("helro helro", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("_supernova", &edit_byte_range_iter);
            try eqStr("helro_supernova helro_supernova", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("X", &edit_byte_range_iter);
            try eqStr("helro_supernovaX helro_supernovaX", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("xyz", &edit_byte_range_iter);
            try eqStr("helro_supernovaXxyz helro_supernovaXxyz", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.deleteChars(3, &edit_byte_range_iter);
            try eqStr("helro_supernovaX helro_supernovaX", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("OXO", &edit_byte_range_iter);
            try eqStr("helro_supernovaXOXO helro_supernovaXOXO", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("helro_supernovaXOXO helro_supernovaXOXO", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }
}

pub fn clear(self: *@This(), buf: *Buffer, cursor_byte_range_iter: anytype) !void {
    assert(self.pending == null);
    self.pending = try PendingEdit.init(self.a, buf, cursor_byte_range_iter);
    try self.pending.?.clear();
}

test clear {
    var orchestrator = Orchestrator{ .a = std.testing.allocator };
    defer orchestrator.deinit();

    { // 1 cursor, clear only
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 6 }} };
        try orchestrator.clear(buf, &initial_byte_range_iter);
        try eqStr("world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        try orchestrator.stopEditing();

        try eqStr("world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    { // 1 cursor, clear then insert
        const buf = try orchestrator.createBufferFromString("hello world");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 5 }} };
        try orchestrator.clear(buf, &initial_byte_range_iter);
        try eqStr(" world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("welcome", &edit_byte_range_iter);
            try eqStr("welcome world", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("welcome world", try buf.toString(std.heap.page_allocator, .lf));
        try eq(2, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(0, buf.edits.items[1].parent_index);
    }

    { // 2 cursors, clear then insert
        const buf = try orchestrator.createBufferFromString("_aaa_ _aaa_");
        try eq(1, buf.edits.items.len);

        var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{
            .{ .start = 1, .end = 4 },
            .{ .start = 7, .end = 10 },
        } };
        try orchestrator.clear(buf, &initial_byte_range_iter);
        try eqStr("__ __", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("b", &edit_byte_range_iter);
            try eqStr("_b_ _b_", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("c", &edit_byte_range_iter);
            try eqStr("_bc_ _bc_", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("XYZ", &edit_byte_range_iter);
            try eqStr("_bcXYZ_ _bcXYZ_", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("|", &edit_byte_range_iter);
            try eqStr("_bcXYZ|_ _bcXYZ|_", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.deleteChars(6, &edit_byte_range_iter);
            try eqStr("__ __", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        {
            var edit_byte_range_iter = try produceMockByteRangeIteratorFromTrackers(&orchestrator);
            try orchestrator.insertChars("x", &edit_byte_range_iter);
            try eqStr("_x_ _x_", try rcr.Node.toString(orchestrator.pending.?.getLatestRoot().value, idc_if_it_leaks, .lf));
        }
        try orchestrator.stopEditing();

        try eqStr("_x_ _x_", try buf.toString(std.heap.page_allocator, .lf));
        try eq(3, buf.edits.items.len);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[0].parent_index);
        try eq(Buffer.NULL_PARENT_INDEX, buf.edits.items[1].parent_index);
        try eq(0, buf.edits.items[2].parent_index);
    }
}

fn produceMockByteRangeIteratorFromTrackers(orchestrator: *const Orchestrator) !MockIterator(ByteRange) {
    const items = try idc_if_it_leaks.alloc(ByteRange, orchestrator.pending.?.trackers.len);
    for (orchestrator.pending.?.trackers, 0..) |*tracker, i| items[i] = ByteRange{ .start = tracker.cursor, .end = tracker.cursor };
    return MockIterator(ByteRange){ .items = items };
}

fn handlePotentialNewPendingEvent(self: *@This(), cursor_byte_range_iter: anytype) !void {
    assert(self.pending != null);

    if (!self.pending.?.shouldCreateNewPendingEvent(cursor_byte_range_iter)) return;

    const buf = self.pending.?.buf;
    try self.pending.?.finalizeChangesToBuffer(self);
    self.pending.?.deinit();

    self.pending = try PendingEdit.init(self.a, buf, cursor_byte_range_iter);
    cursor_byte_range_iter.reset(); // reset iterator index to 0 for subsequent `insertChars` or `deleteChars` calls.
}

pub fn stopEditing(self: *@This()) !void {
    assert(self.pending != null);
    try self.pending.?.finalizeChangesToBuffer(self);
    self.pending.?.deinit();
    self.pending = null;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn MockIterator(T: type) type {
    return struct {
        items: []const T,
        index: usize = 0,

        pub fn next(self: *@This()) ?T {
            defer self.index += 1;
            if (self.index >= self.items.len) return null;
            return self.items[self.index];
        }

        pub fn len(self: *const @This()) usize {
            return self.items.len;
        }

        pub fn first(self: *const @This()) T {
            return self.items[0];
        }

        pub fn reset(self: *@This()) void {
            self.index = 0;
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
