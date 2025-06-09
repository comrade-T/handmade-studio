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
pub const InsertManager = @import("InsertManager.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

index: u32 = 0,
edits: ListOfEdits = .{},

const ListOfEdits = std.ArrayListUnmanaged(Edit);
const NULL_PARENT_INDEX = std.math.maxInt(u32);
const Edit = struct {
    parent_index: u32 = NULL_PARENT_INDEX,
    root: rcr.RcNode,
    old_start_byte: u32,
    old_end_byte: u32,
    new_start_byte: u32,
    new_end_byte: u32,
};

////////////////////////////////////////////////////////////////////////////////////////////// Init

pub fn initFromFile(a: Allocator, insert_manager: *InsertManager, path: []const u8) !NeoBuffer {
    const allocated_str, const root = try rcr.Node.fromFile(a, insert_manager.a, path);
    return create(a, insert_manager, allocated_str, root);
}

pub fn initFromString(a: Allocator, insert_manager: *InsertManager, str: []const u8) !NeoBuffer {
    const allocated_str, const root = try rcr.Node.fromString(a, insert_manager.a, str);
    return create(a, insert_manager, allocated_str, root);
}

test initFromString {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buf = try NeoBuffer.initFromString(a, arena.allocator(), "hello world");
    defer buf.deinit(a);

    try eqStr("hello world", try buf.toString(idc_if_it_leaks, .lf));
}

fn create(a: Allocator, insert_manager: *InsertManager, allocated_str: []const u8, root: rcr.RcNode) !*NeoBuffer {
    const self = try a.create(NeoBuffer);
    self.* = NeoBuffer{};
    try self.edits.append(a, Edit{
        .root = root,
        .old_start_byte = 0,
        .old_end_byte = 0,
        .new_start_byte = 0,
        .new_end_byte = root.value.weights().len,
    });
    try insert_manager.initBuffer(self, allocated_str);
    return self;
}

pub fn destroy(self: *@This(), a: Allocator) void {
    for (self.edits.items) |edit| rcr.freeRcNode(a, edit.root);
    self.edits.deinit(a);
    a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert

const EditType = enum { interim, registered };

pub const InsertCharsRequest = struct {
    parent_index: u32,
    edit_type: EditType,

    chars: []const u8,
    start_byte: u32,
    start_line: u32,
    start_col: u32,
};

pub fn insertChars(self: *@This(), a: Allocator, req: InsertCharsRequest) ![]const u8 {
    const result = try rcr.insertChars(self.getCurrentRoot(), a, req.chars, .{
        .line = @intCast(req.start_line),
        .col = @intCast(req.start_col),
    });

    try self.addEditToHistory(a, req.edit_type, req.parent_index, Edit{
        .root = try balance(a, result.node),
        .old_start_byte = req.start_byte,
        .old_end_byte = req.start_byte,
        .new_start_byte = req.start_byte,
        .new_end_byte = req.start_byte + @as(u32, @intCast(req.chars.len)),
    });

    return result.allocated_str;
}

test insertChars {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buf = try NeoBuffer.initFromString(a, arena.allocator(), "hello world");
    defer buf.deinit(a);

    _ = try buf.insertChars(a, arena.allocator(), InsertCharsRequest{
        .parent_index = buf.index,
        .edit_type = .registered,
        .chars = "// ",
        .start_byte = 0,
        .start_line = 0,
        .start_col = 0,
    });

    try eq(2, buf.edits.items.len);
    try eqStr("// hello world", try buf.toString(idc_if_it_leaks, .lf));
}

////////////////////////////////////////////////////////////////////////////////////////////// Delete

const DeleteRangeRequest = struct {
    parent_index: u32,
    edit_type: EditType,

    start_byte: u32,
    end_byte: u32,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub fn deleteRange(self: *@This(), a: Allocator, req: DeleteRangeRequest) !void {
    const noc = rcr.getNocOfRange(
        self.getCurrentRoot(),
        .{ .line = @intCast(req.start_line), .col = @intCast(req.start_col) },
        .{ .line = @intCast(req.end_line), .col = @intCast(req.end_col) },
    );
    const new_root = try rcr.deleteChars(
        self.getCurrentRoot(),
        a,
        .{ .line = @intCast(req.start_line), .col = @intCast(req.start_col) },
        noc,
    );

    try self.addEditToHistory(a, req.edit_type, req.parent_index, Edit{
        .root = try balance(a, new_root),
        .old_start_byte = req.start_byte,
        .old_end_byte = req.end_byte,
        .new_start_byte = req.start_byte,
        .new_end_byte = req.start_byte,
    });
}

test deleteRange {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buf = try NeoBuffer.initFromString(a, arena.allocator(), "hello world");
    defer buf.deinit(a);

    _ = try buf.deleteRange(a, DeleteRangeRequest{
        .parent_index = buf.index,
        .edit_type = .registered,

        .start_byte = 5,
        .end_byte = 10,
        .start_line = 0,
        .start_col = 5,
        .end_line = 0,
        .end_col = 10,
    });

    try eq(2, buf.edits.items.len);
    try eqStr("hellod", try buf.toString(idc_if_it_leaks, .lf));
}

////////////////////////////////////////////////////////////////////////////////////////////// Replace

const ReplaceRangeRequest = struct {
    parent_index: u32,
    edit_type: EditType,

    chars: []const u8,
    start_byte: u32,
    end_byte: u32,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub fn replaceRange(self: *@This(), a: Allocator, content_allocator: Allocator, req: ReplaceRangeRequest) ![]const u8 {
    const noc = rcr.getNocOfRange(
        self.getCurrentRoot(),
        .{ .line = @intCast(req.start_line), .col = @intCast(req.start_col) },
        .{ .line = @intCast(req.end_line), .col = @intCast(req.end_col) },
    );
    const after_delete_root = try rcr.deleteChars(
        self.getCurrentRoot(),
        a,
        .{ .line = @intCast(req.start_line), .col = @intCast(req.start_col) },
        noc,
    );
    const balanced_after_delete_root = try balance(a, after_delete_root);
    defer rcr.freeRcNode(a, balanced_after_delete_root);

    const insert_result = try rcr.insertChars(balanced_after_delete_root, a, content_allocator, req.chars, .{
        .line = @intCast(req.start_line),
        .col = @intCast(req.start_col),
    });

    try self.addEditToHistory(a, req.edit_type, req.parent_index, Edit{
        .root = try balance(a, insert_result.node),
        .old_start_byte = req.start_byte,
        .old_end_byte = req.end_byte,
        .new_start_byte = req.start_byte,
        .new_end_byte = req.start_byte + @as(u32, @intCast(req.chars.len)),
    });

    return insert_result.allocated_str;
}

test replaceRange {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var buf = try NeoBuffer.initFromString(a, arena.allocator(), "hello world");
    defer buf.deinit(a);

    _ = try buf.replaceRange(a, arena.allocator(), ReplaceRangeRequest{
        .parent_index = buf.index,
        .edit_type = .registered,

        .chars = "goo",
        .start_byte = 6,
        .end_byte = 10,
        .start_line = 0,
        .start_col = 6,
        .end_line = 0,
        .end_col = 10,
    });

    try eq(2, buf.edits.items.len);
    try eqStr("hello good", try buf.toString(idc_if_it_leaks, .lf));
}

////////////////////////////////////////////////////////////////////////////////////////////// Getters

pub fn toString(self: *const @This(), a: Allocator, eol_mode: rcr.EolMode) ![]const u8 {
    return self.getCurrentRoot().value.toString(a, eol_mode);
}

pub fn getRange(self: *const @This(), start: rcr.EditPoint, end: ?rcr.EditPoint, buf: []u8) ![]const u8 {
    return rcr.getRange(self.getCurrentRoot(), start, end, buf);
}

pub fn getNumOfCharsInLine(self: *const @This(), line: usize) usize {
    return rcr.getNumOfCharsInLine(self.getCurrentRoot(), line);
}

////////////////////////////////////////////////////////////////////////////////////////////// History

fn addEditToHistory(self: *@This(), a: Allocator, edit_type: EditType, parent_index: u32, edit: Edit) !void {
    defer self.index += 1;
    try self.edits.append(a, edit);
    if (edit_type == .interim) return;
    self.edits.items[self.edits.items.len - 1].parent_index = parent_index;
}

////////////////////////////////////////////////////////////////////////////////////////////// Private

fn balance(a: Allocator, node: rcr.RcNode) !rcr.RcNode {
    const is_rebalanced, const balanced_root = try rcr.balance(a, node);
    if (is_rebalanced) rcr.freeRcNode(a, node);
    return balanced_root;
}

pub fn getCurrentRoot(self: *const @This()) rcr.RcNode {
    assert(self.edits.items.len > 0);
    assert(self.index < self.edits.items.len);

    return self.edits.items[self.index].root;
}
