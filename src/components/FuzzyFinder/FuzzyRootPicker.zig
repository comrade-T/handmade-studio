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

previous_prefix: []const u8 = "",
current_entries: std.ArrayListUnmanaged([]const u8) = .{},

const Entry = struct {
    kind: std.fs.File.Kind,
    name: []const u8,
};

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
    self.freePreviousPrefixIfNeeded();
    self.clearCurrentEntries();
    self.current_entries.deinit(self.a);
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn clearCurrentEntries(self: *@This()) void {
    for (self.current_entries.items) |entry| self.a.free(entry);
    self.current_entries.clearRetainingCapacity();
}

fn freePreviousPrefixIfNeeded(self: *@This()) void {
    if (self.previous_prefix.len > 0) self.a.free(self.previous_prefix);
}

fn setPreviousPrefix(self: *@This(), new_prefix: []const u8) !void {
    self.freePreviousPrefixIfNeeded();
    self.previous_prefix = try self.a.dupe(u8, new_prefix);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn updater(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    for (self.current_entries.items) |entry| {
        const path = try std.fmt.allocPrint(self.a, "{s}{s}/", .{ self.previous_prefix, entry });
        defer self.a.free(path);
        try self.finder.addEntry(path);
    }
}

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.finder.getSelectedPath() orelse return true;
    std.debug.print("got path: '{s}'\n", .{path});
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FRP);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

fn onUpdate(ctx: *anyopaque, needle: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    /////////////////////////////

    var i: usize = needle.len;
    while (i > 0) {
        i -= 1;
        if (needle[i] == '/') {
            i += 1;
            break;
        }
    }

    const prefix = needle[0..i];

    /////////////////////////////

    if (prefix.len == 0) {
        self.freePreviousPrefixIfNeeded();
        self.previous_prefix = "";
        return;
    }

    var dir = std.fs.openDirAbsolute(prefix, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("file not found | TODO: handle this\n", .{});
            return;
        },
        else => {
            std.debug.print("got err: '{any}' | TODO: handle this\n", .{err});
            return;
        },
    };
    defer dir.close();

    if (!std.mem.eql(u8, self.previous_prefix, prefix)) {
        self.clearCurrentEntries();

        var iter = dir.iterate();
        while (iter.next() catch |err| {
            std.debug.print("got err: '{any}'\n", .{err});
            return;
        }) |entry| {
            try self.current_entries.append(self.a, try self.a.dupe(u8, entry.name));
        }

        try self.setPreviousPrefix(prefix);
    }

    try self.finder.updateEntries();
}

fn tab(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.finder.getSelectedPath() orelse return;
    try self.finder.replaceInputContents(path);
}
