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
const Nightfly = Session.RenderMall.ColorschemeStore.Nightfly;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
finder: *FuzzyFinder,
sess: *Session,
targets: TargetList = .{},
smap: Session.StrategicMap = .{
    .background = null,
    .padding = .{
        .left = .{ .screen_percentage = 0.5, .quant = 10 },
        .right = .{ .min = 80, .quant = 20 },
        .top = .{ .screen_percentage = 0.2, .quant = 10 },
        .bottom = .{ .screen_percentage = 0.2, .quant = 10 },
    },
},
filter_color: ?u32 = null,

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

    try c.map(FSWJ, &.{ .left_alt, .space }, .{ .f = disableFilter, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .o }, .{ .f = setFilterToOnlyShowPurple, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .i }, .{ .f = setFilterToOnlyShowBlue, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .l }, .{ .f = setFilterToOnlyShowGreen, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .j }, .{ .f = setFilterToOnlyShowGray, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .k }, .{ .f = setFilterToOnlyShowYellow, .ctx = fswj });
    try c.map(FSWJ, &.{ .left_alt, .zero }, .{ .f = setFilterToOnlyShowWhite, .ctx = fswj });
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
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onShow = .{ .f = onShow, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
            .updater = .{ .f = updater, .ctx = self },
            .postRender = .{ .f = postRender, .ctx = self },
            .getEntryColor = .{ .f = getEntryColor, .ctx = self },
            .fill_selected_entry_with_matched_color = false,
            .render_vertical_line_at_selected_entry = true,
            .y_distance_between_entries = 10,
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

fn onShow(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.smap.show();
}

fn updater(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.updateTargets();
}

fn onConfirm(ctx: *anyopaque, _: []const u8) !bool {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const index = self.finder.getSelectedIndex() orelse return true;
    const win = self.targets.items[index];
    win.centerCameraInstantlyAt(self.sess.mall);
    const wm = self.sess.getActiveCanvasWindowManager() orelse return true;
    wm.setActiveWindow(win, true);
    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FSWJ);
    try self.finder.doi.council.addActiveContext(NORMAL);
    self.smap.hide();
}

fn postRender(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const index = self.finder.getSelectedIndex() orelse return;
    self.smap.render(self.sess, self.targets.items[index]);
}

fn getEntryColor(ctx: *anyopaque, idx: usize) !u32 {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    return self.targets.items[idx].defaults.color;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn setFilterToOnlyShowWhite(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(0xF5F5F5F5);
}
fn setFilterToOnlyShowGreen(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(0x00FF00F5);
}
fn setFilterToOnlyShowYellow(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(0xFFFF00F5);
}
fn setFilterToOnlyShowGray(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(0x555555F5);
}

fn setFilterToOnlyShowPurple(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(@intFromEnum(Nightfly.purple));
}
fn setFilterToOnlyShowBlue(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(@intFromEnum(Nightfly.blue));
}

fn disableFilter(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.changeFilterColorAndRefreshFinderEntries(null);
}

fn changeFilterColorAndRefreshFinderEntries(self: *@This(), color: ?u32) !void {
    self.filter_color = color;
    try self.finder.refreshEntries();
}

fn updateTargets(self: *@This()) !void {
    const wm = self.sess.getActiveCanvasWindowManager() orelse return;
    self.targets.clearRetainingCapacity();

    for (wm.wmap.keys()) |window| {
        if (window.closed or window.ws.origin == .file) continue;
        if (self.filter_color) |color| if (window.defaults.color != color) continue;

        const str = try window.ws.buf.ropeman.toString(self.finder.entry_arena.allocator(), .lf);
        try self.targets.append(self.a, window);
        try self.finder.addEntryUnmanaged(str);
    }
}
