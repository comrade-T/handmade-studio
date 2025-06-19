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

const NeoBuffer = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const assert = std.debug.assert;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

pub const rcr = @import("NeoRcRope.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

index: u32 = 0,
edits: ListOfEdits = .{},

pub const NULL_PARENT_INDEX = std.math.maxInt(u32);
const ListOfEdits = std.ArrayListUnmanaged(Edit);
const Edit = struct {
    parent_index: u32,
    root: rcr.RcNode,
    old_start_byte: u32,
    old_end_byte: u32,
    new_start_byte: u32,
    new_end_byte: u32,
};

test {
    try eq(8, @alignOf(Edit));
    try eq(32, @sizeOf(Edit));

    try eq(8, @alignOf(NeoBuffer));
    try eq(24, @sizeOf(ListOfEdits));
    try eq(32, @sizeOf(NeoBuffer));
}

////////////////////////////////////////////////////////////////////////////////////////////// Init

pub fn create(a: Allocator, root: rcr.RcNode) !*NeoBuffer {
    const self = try a.create(NeoBuffer);
    self.* = NeoBuffer{};
    try self.edits.append(a, Edit{
        .parent_index = NULL_PARENT_INDEX,
        .root = root,
        .old_start_byte = 0,
        .old_end_byte = 0,
        .new_start_byte = 0,
        .new_end_byte = root.value.weights().len,
    });
    return self;
}

pub fn destroy(self: *@This(), a: Allocator) void {
    for (self.edits.items) |edit| rcr.freeRcNode(a, edit.root);
    self.edits.deinit(a);
    a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Getters

pub fn toString(self: *const @This(), a: Allocator, eol_mode: rcr.EolMode) ![]const u8 {
    return self.getCurrentRoot().value.toString(a, eol_mode);
}

pub fn getRange(self: *const @This(), start: rcr.EditPoint, end: ?rcr.EditPoint, buf: []u8) []const u8 {
    return rcr.getRange(self.getCurrentRoot(), start, end, buf);
}

pub fn getNumOfCharsInLine(self: *const @This(), line: usize) usize {
    return rcr.getNumOfCharsInLine(self.getCurrentRoot(), line);
}

pub fn getByteOffsetOfPosition(self: *const @This(), line: u32, col: u32) !u32 {
    return rcr.getByteOffsetOfPosition(self.getCurrentRoot(), line, col);
}

pub fn getLineCount(self: *const @This()) u32 {
    return self.getCurrentRoot().value.weights().bols;
}

pub fn getCurrentRoot(self: *const @This()) rcr.RcNode {
    assert(self.edits.items.len > 0);
    assert(self.index < self.edits.items.len);

    return self.edits.items[self.index].root;
}

////////////////////////////////////////////////////////////////////////////////////////////// Add Edit

pub const AddEditRequest = struct {
    parent_index: u32,
    chars: []const u8,

    old_start_byte: u32,
    old_end_byte: u32,
    new_start_byte: u32,
    new_end_byte: u32,

    delete_start_line: u32,
    delete_start_col: u32,
    delete_end_line: u32,
    delete_end_col: u32,
};

pub fn addEdit(self: *@This(), a: Allocator, req: AddEditRequest) !void {
    const should_delete = !(req.delete_start_line == req.delete_end_line and req.delete_start_col == req.delete_end_col);

    const balanced_after_delete_root = if (should_delete) blk: {
        const after_delete_root = try rcr.deleteRange(
            self.getCurrentRoot(),
            a,
            .{ .line = req.delete_start_line, .col = req.delete_start_col },
            .{ .line = req.delete_end_line, .col = req.delete_end_col },
        );
        const balanced = try balance(a, after_delete_root);
        break :blk balanced;
    } else self.getCurrentRoot();
    defer if (should_delete and req.chars.len > 0) rcr.freeRcNode(a, balanced_after_delete_root);

    var inserted_root = balanced_after_delete_root;
    if (req.chars.len > 0) {
        const res = try rcr.insertChars(balanced_after_delete_root, a, req.chars, .{
            .line = @intCast(req.delete_start_line),
            .col = @intCast(req.delete_start_col),
        });
        inserted_root = res.node;
    }

    try self.edits.append(a, Edit{
        .parent_index = req.parent_index,
        .root = try balance(a, inserted_root),
        .old_start_byte = req.old_start_byte,
        .old_end_byte = req.old_end_byte,
        .new_start_byte = req.new_start_byte,
        .new_end_byte = req.new_end_byte,
    });
    self.index = @as(u32, @intCast(self.edits.items.len)) - 1;
}

fn balance(a: Allocator, node: rcr.RcNode) !rcr.RcNode {
    const is_rebalanced, const balanced_root = try rcr.balance(a, node);
    if (is_rebalanced) rcr.freeRcNode(a, node);
    return balanced_root;
}
