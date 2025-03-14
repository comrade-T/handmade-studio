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
const WindowManager = @import("WindowManager");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FEP = "FuzzyEntityPicker";

a: Allocator,
finder: *FuzzyFinder,
wm: *WindowManager,

pub fn mapKeys(fep: *@This(), c: *ip.MappingCouncil) !void {
    try c.map(NORMAL, &.{ .space, .e }, .{
        .f = FuzzyFinder.show,
        .ctx = fep.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FEP} },
        .require_clarity_afterwards = true,
    });
}

pub fn create(a: Allocator, wm: *WindowManager, doi: *DepartmentOfInputs) !*FuzzyEntityPicker {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .wm = wm,
        .finder = try FuzzyFinder.create(a, doi, .{
            .input_name = FEP,
            .kind = .files,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .updateEntries = .{ .f = updateEntries, .ctx = self },
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
    const entry = self.finder.getSelectedPath() orelse return true;

    std.debug.print("selected entry: '{s}'\n", .{entry});

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

    const win = self.wm.active_window orelse return;
    const buf = win.ws.buf;
    const captured_list = try buf.captureEntitiesToArrayList(self.a);
    defer captured_list.deinit();

    for (captured_list.items) |capture| {
        var txt_buf: [256]u8 = undefined;
        const contents = buf.ropeman.getRange(
            .{ .line = capture.start_line, .col = capture.start_col },
            .{ .line = capture.end_line, .col = capture.end_col },
            &txt_buf,
        );
        try self.finder.addEntry(contents);
    }
}
