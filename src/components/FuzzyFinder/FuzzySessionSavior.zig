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

const FuzzySessionSavior = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ip = @import("input_processor");
const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const FuzzyFileCreator = @import("FuzzyFileCreator.zig");
const WindowManager = @import("WindowManager");
const ConfirmationPrompt = @import("ConfirmationPrompt");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FSS = "FuzzySessionSavior";

a: Allocator,
wm: *WindowManager,
ffc: *FuzzyFileCreator,

pub fn mapKeys(ffs: *@This(), c: *ip.MappingCouncil) !void {
    const cb = ip.Callback{
        .f = FuzzyFinder.show,
        .ctx = ffs.ffc.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FSS} },
        .require_clarity_afterwards = true,
    };
    try c.map(NORMAL, &.{ .left_control, .left_shift, .s }, cb);
    try c.map(NORMAL, &.{ .left_shift, .left_control, .s }, cb);
}

pub fn create(a: Allocator, wm: *WindowManager, doi: *DepartmentOfInputs, cp: *ConfirmationPrompt) !*FuzzySessionSavior {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .wm = wm,
        .ffc = try FuzzyFileCreator.create(a, .{
            .kind = .both,
            .name = "FuzzySessionSavior",
            .file_callback = .{ .f = postConfirmCallback, .ctx = self },
            .ignore_ignore_patterns = &.{".handmade_studio/"},
            .custom_match_patterns = &.{"*.json"},
        }, doi, cp),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.ffc.destroy();
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn postConfirmCallback(ctx: *anyopaque, path: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.wm.saveSession(path);
}
