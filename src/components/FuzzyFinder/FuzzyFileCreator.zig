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
const Kind = @import("path_getters.zig").AppendFileNamesRequest.Kind;
const ConfirmationPrompt = @import("ConfirmationPrompt");
const NotificationLine = @import("NotificationLine");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";

a: Allocator,
finder: *FuzzyFinder,
new_file_origin: []const u8 = "",
opts: Opts,

const Opts = struct {
    name: []const u8,
    kind: Kind,
    file_callback: ?FuzzyFinder.Callback = null,

    custom_ignore_patterns: ?[]const []const u8 = null,
    ignore_ignore_patterns: ?[]const []const u8 = null,
    custom_match_patterns: ?[]const []const u8 = null,
};

pub fn mapKeys(ffc: *@This(), c: *ip.MappingCouncil) !void {
    try c.map(ffc.opts.name, &.{ .left_alt, .c }, .{ .f = forceConfirm, .ctx = ffc });
}

pub fn create(a: Allocator, opts: Opts, doi: *DepartmentOfInputs, cp: *ConfirmationPrompt, nl: *NotificationLine) !*FuzzyFileCreator {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .opts = opts,
        .finder = try FuzzyFinder.create(a, doi, .{
            .cp = cp,
            .nl = nl,

            .input_name = opts.name,
            .kind = opts.kind,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },

            .custom_ignore_patterns = opts.custom_ignore_patterns,
            .ignore_ignore_patterns = opts.ignore_ignore_patterns,
            .custom_match_patterns = opts.custom_match_patterns,
        }),
    };
    try self.mapKeys(doi.council);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.cleanUpNewFileOrigin();
    self.finder.destroy();
    self.a.destroy(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn onConfirm(ctx: *anyopaque, input_contents: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    if (self.finder.getSelectedPath()) |path| {
        if (try self.executeFileCallback(path)) return true;

        assert(try self.finder.doi.replaceInputContent(self.opts.name, path));
        self.cleanUpNewFileOrigin();
        self.new_file_origin = try self.a.dupe(u8, path);
        return false;
    }

    try self.createFile(self.new_file_origin, input_contents);
    _ = try self.executeFileCallback(input_contents);
    return true;
}

fn forceConfirm(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.createFile("", self.finder.needle);
    _ = try self.executeFileCallback(self.finder.needle);
    try FuzzyFinder.hide(self.finder);
}

fn executeFileCallback(self: *@This(), path: []const u8) !bool {
    if (isFile(path)) {
        if (self.opts.file_callback) |cb| {
            try cb.f(cb.ctx, path);
            return true;
        }
    }
    return false;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cleanUpNewFileOrigin();
    try self.finder.doi.council.removeActiveContext(self.opts.name);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

fn cleanUpNewFileOrigin(self: *@This()) void {
    if (self.new_file_origin.len > 0) {
        self.a.free(self.new_file_origin);
        self.new_file_origin = "";
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn isFile(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    const stat = file.stat() catch return false;
    return stat.kind == .file;
}

fn createFile(self: *@This(), origin_: []const u8, new_file_path: []const u8) !void {
    const origin = if (origin_.len > 0) origin_ else ".";

    const new_part = if (origin_.len > 0) new_file_path[origin.len..] else new_file_path;
    var split = std.mem.split(u8, new_part, "/");

    var dir = try std.fs.cwd().openDir(origin, .{});
    defer dir.close();

    while (split.next()) |part| {
        if (split.peek() == null) {
            if (part.len == 0) break;
            var file = try dir.createFile(part, .{});
            defer file.close();
            break;
        }
        dir.makeDir(part) catch {};
        const new_dir = try dir.openDir(part, .{});
        dir.close();
        dir = new_dir;
    }

    const msg = try std.fmt.allocPrint(self.a, "File '{s}' created successfully", .{new_file_path});
    defer self.a.free(msg);
    try self.finder.opts.nl.setMessage(msg);
}
