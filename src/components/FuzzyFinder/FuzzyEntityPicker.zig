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

const FuzzyEntityPicker = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ip = @import("input_processor");
const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const Session = @import("Session");
const Buffer = @import("Buffer");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FEP = "FuzzyEntityPicker";

a: Allocator,
finder: *FuzzyFinder,
sess: *Session,
entity_list: Buffer.EntityList,

pub fn mapKeys(fep: *@This(), c: *ip.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .space, .e }, .{
        .f = FuzzyFinder.show,
        .ctx = fep.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FEP} },
        .require_clarity_afterwards = true,
    });
}

pub fn create(a: Allocator, sess: *Session, doi: *DepartmentOfInputs) !*FuzzyEntityPicker {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .sess = sess,
        .finder = try FuzzyFinder.create(a, doi, .{
            .input_name = FEP,
            .kind = .files,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .updateEntries = .{ .f = updateEntries, .ctx = self },
        }),
        .entity_list = Buffer.EntityList.init(a),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.finder.destroy();
    self.entity_list.deinit();
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const index = self.finder.getSelectedIndex() orelse return true;

    const wm = self.sess.getActiveCanvasWindowManager() orelse return false;
    const win = wm.active_window orelse return false;
    assert(index < self.entity_list.items.len);
    const entity = self.entity_list.items[index];

    try win.setLimit(wm.a, wm.qtree, .{
        .start_line = entity.contents.start_line,
        .end_line = entity.contents.end_line,
    });

    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FEP);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn updateEntries(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.entity_list.clearRetainingCapacity();

    const wm = self.sess.getActiveCanvasWindowManager() orelse return;
    const win = wm.active_window orelse return;
    const buf = win.ws.buf;
    try buf.captureEntitiesToArrayList(&self.entity_list);

    for (self.entity_list.items) |entity| {
        var txt_buf: [256]u8 = undefined;
        const contents = buf.ropeman.getRange(
            .{ .line = entity.name.start_line, .col = entity.name.start_col },
            .{ .line = entity.name.end_line, .col = entity.name.end_col },
            &txt_buf,
        );
        try self.finder.addEntry(contents);
    }
}
