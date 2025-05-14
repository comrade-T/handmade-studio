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

const FuzzyStringWindowJumper = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const Session = @import("Session");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
finder: *FuzzyFinder,
sess: *Session,
targets: TargetList = .{},

const TargetList = std.ArrayListUnmanaged(*Session.WindowManager.Window);

const NORMAL = "normal";
const FSWJ = "FuzzyStringWindowJumper";

pub fn mapKeys(fswj: *@This(), c: *Session.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .space, .j }, .{
        .f = FuzzyFinder.show,
        .ctx = fswj.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FSWJ} },
        .require_clarity_afterwards = true,
    });
}

pub fn create(
    a: Allocator,
    sess: *Session,
    doi: *DepartmentOfInputs,
) !*FuzzyStringWindowJumper {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .sess = sess,
        .finder = try FuzzyFinder.create(a, doi, .{
            .input_name = FSWJ,
            .kind = .files,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .updater = .{ .f = updater, .ctx = self },
        }),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.finder.destroy();
    self.targets.deinit(self.a);
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn updater(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const wm = self.sess.getActiveCanvasWindowManager() orelse return;
    self.targets.clearRetainingCapacity();

    for (wm.wmap.keys()) |window| {
        if (window.closed or window.ws.path.len > 0) continue;
        const str = try window.ws.buf.ropeman.toString(self.finder.entry_arena.allocator(), .lf);
        try self.targets.append(self.a, window);
        try self.finder.addEntryUnmanaged(str);
    }
}

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const index = self.finder.getSelectedIndex() orelse return true;
    const win = self.targets.items[index];
    win.centerCameraAt(self.sess.mall);
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FSWJ);
    try self.finder.doi.council.addActiveContext(NORMAL);
}
