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

const FuzzySessionOpener = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const Session = @import("Session");
const ConfirmationPrompt = @import("ConfirmationPrompt");
const NotificationLine = @import("NotificationLine");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FSO = "FuzzySessionOpener";

a: Allocator,
finder: *FuzzyFinder,
sess: *Session,

pub fn mapKeys(fso: *@This(), c: *Session.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .space, .s }, .{
        .f = FuzzyFinder.show,
        .ctx = fso.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FSO} },
        .require_clarity_afterwards = true,
    });
}

pub fn create(
    a: Allocator,
    sess: *Session,
    doi: *DepartmentOfInputs,
    cp: *ConfirmationPrompt,
    nl: *NotificationLine,
) !*FuzzySessionOpener {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .sess = sess,
        .finder = try FuzzyFinder.create(a, doi, .{
            .cp = cp,
            .nl = nl,
            .input_name = FSO,
            .kind = .files,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .ignore_ignore_patterns = &.{".handmade_studio/"},
            .custom_match_patterns = &.{"*.json"},
            .sort_by_mtime = .on_empty_needle,
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

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.finder.getSelectedPath() orelse return true;
    try self.sess.loadCanvasFromFile(path);
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FSO);
    try self.finder.doi.council.addActiveContext(NORMAL);
}
