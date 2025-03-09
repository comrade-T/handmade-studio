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

const FuzzyFileCreator = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ip = @import("input_processor");
const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FFC = "FuzzyFileCreator";

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
finder: *FuzzyFinder,
new_file_origin: []const u8 = "",

pub fn mapKeys(ffo: *@This(), c: *ip.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .left_control, .s }, .{
        .f = FuzzyFinder.show,
        .ctx = ffo.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FFC} },
        .require_clarity_afterwards = true,
    });
}

pub fn create(a: Allocator, doi: *DepartmentOfInputs) !*FuzzyFileCreator {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .finder = try FuzzyFinder.create(a, doi, .{
            .input_name = FFC,
            .kind = .directories,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
        }),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    if (self.new_file_origin.len > 0) {
        self.a.free(self.new_file_origin);
        self.new_file_origin = "";
    }
    self.finder.destroy();
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn onConfirm(ctx: *anyopaque, input_contents: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    if (self.finder.getSelectedPath()) |dir_path| {
        assert(try self.finder.doi.replaceInputContent(FFC, dir_path));
        self.new_file_origin = try self.a.dupe(u8, dir_path);
        return false;
    }

    assert(self.new_file_origin.len > 0);
    try createFile(self.new_file_origin, input_contents);
    std.debug.print("created '{s}' successfully\n", .{input_contents});
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.new_file_origin.len > 0) {
        self.a.free(self.new_file_origin);
        self.new_file_origin = "";
    }
    try self.finder.doi.council.removeActiveContext(FFC);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn createFile(origin: []const u8, new_file_path: []const u8) !void {
    const new_part = new_file_path[origin.len..];
    var split = std.mem.split(u8, new_part, "/");

    var dir = try std.fs.cwd().openDir(origin, .{});
    defer dir.close();

    while (split.next()) |part| {
        if (split.peek() == null) {
            var file = try dir.createFile(part, .{});
            defer file.close();
            break;
        }
        try dir.makeDir(part);
        const new_dir = try dir.openDir(part, .{});
        dir.close();
        dir = new_dir;
    }
}
