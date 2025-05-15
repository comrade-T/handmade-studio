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

const FuzzyRootPicker = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const Session = @import("Session");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
finder: *FuzzyFinder,
sess: *Session,

const NORMAL = "normal";
const FRP = "FuzzyRootPicker";

pub fn mapKeys(frp: *@This(), c: *Session.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .space, .r }, .{
        .f = FuzzyFinder.show,
        .ctx = frp.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FRP} },
        .require_clarity_afterwards = true,
    });
    try c.map(FRP, &.{.tab}, .{ .f = tab, .ctx = frp });
}

pub fn create(
    a: Allocator,
    sess: *Session,
    doi: *DepartmentOfInputs,
) !*FuzzyRootPicker {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .sess = sess,
        .finder = try FuzzyFinder.create(a, doi, .{
            .input_name = FRP,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .updater = .{ .f = updater, .ctx = self },
            .onUpdate = .{ .f = onUpdate, .ctx = self },
        }),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.finder.destroy();
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn updater(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    _ = self;
}

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    _ = self;
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FRP);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

fn onUpdate(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    const needle = self.finder.needle;
    var i: usize = needle.len;
    while (i > 0) {
        i -= 1;
        if (needle[i] == '/') {
            i += 1;
            break;
        }
    }

    const dir_path = needle[0..i];
    std.debug.print("dir_path: '{s}'\n", .{dir_path});
}

fn tab(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    _ = self;
}
