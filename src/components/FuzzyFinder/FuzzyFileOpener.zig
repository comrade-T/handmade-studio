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

const FuzzyFileOpener = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ip = @import("input_processor");
const DepartmentOfInputs = @import("DepartmentOfInputs");
const FuzzyFinder = @import("FuzzyFinder.zig");
const WindowManager = @import("WindowManager");
const AnchorPicker = @import("AnchorPicker");
const ConfirmationPrompt = @import("ConfirmationPrompt");
const NotificationLine = @import("NotificationLine");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FFO = "FuzzyFileOpener";
const FFO_TO_NORMAL = ip.Callback.Contexts{ .remove = &.{FFO}, .add = &.{NORMAL} };

a: Allocator,
finder: *FuzzyFinder,
wm: *WindowManager,
ap: *AnchorPicker,

pub fn mapKeys(ffo: *@This(), c: *ip.MappingCouncil) !void {
    const a = c.arena.allocator();

    // mode enter & exit
    try c.map(NORMAL, &.{ .left_control, .f }, .{
        .f = FuzzyFinder.show,
        .ctx = ffo.finder,
        .contexts = .{ .remove = &.{NORMAL}, .add = &.{FFO} },
        .require_clarity_afterwards = true,
    });

    // spawn
    const RelativeSpawnCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        target: *FuzzyFileOpener,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.spawnRelativeToActiveWindow(self.direction);
        }
        pub fn init(allocator: Allocator, ctx: *anyopaque, direction: WindowManager.WindowRelativeDirection) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*FuzzyFileOpener, @ptrCast(@alignCast(ctx)));
            self.* = .{ .direction = direction, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .contexts = FFO_TO_NORMAL };
        }
    };
    try c.map(FFO, &.{ .left_control, .v }, try RelativeSpawnCb.init(a, ffo, .right));
    try c.map(FFO, &.{ .left_control, .left_shift, .v }, try RelativeSpawnCb.init(a, ffo, .left));
    try c.map(FFO, &.{ .left_shift, .left_control, .v }, try RelativeSpawnCb.init(a, ffo, .left));
    try c.map(FFO, &.{ .left_control, .x }, try RelativeSpawnCb.init(a, ffo, .bottom));
    try c.map(FFO, &.{ .left_control, .left_shift, .x }, try RelativeSpawnCb.init(a, ffo, .top));
    try c.map(FFO, &.{ .left_shift, .left_control, .x }, try RelativeSpawnCb.init(a, ffo, .top));
}

pub fn create(
    a: Allocator,
    wm: *WindowManager,
    ap: *AnchorPicker,
    doi: *DepartmentOfInputs,
    cp: *ConfirmationPrompt,
    nl: *NotificationLine,
) !*FuzzyFileOpener {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .wm = wm,
        .ap = ap,
        .finder = try FuzzyFinder.create(a, doi, .{
            .cp = cp,
            .nl = nl,
            .input_name = FFO,
            .kind = .files,
            .onConfirm = .{ .f = onConfirm, .ctx = self },
            .onHide = .{ .f = onHide, .ctx = self },
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

    const x, const y = self.finder.doi.mall.icb.getScreenToWorld2D(
        self.finder.doi.mall.camera,
        self.ap.target_anchor.x,
        self.ap.target_anchor.y,
    );

    try self.wm.spawnWindow(.file, path, .{
        .pos = .{ .x = x, .y = y },
        .subscribed_style_sets = &.{0},
    }, true, true);

    return true;
}

fn onHide(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.finder.doi.council.removeActiveContext(FFO);
    try self.finder.doi.council.addActiveContext(NORMAL);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn spawnRelativeToActiveWindow(self: *@This(), direction: WindowManager.WindowRelativeDirection) !void {
    const path = self.finder.getSelectedPath() orelse return;
    try self.wm.spawnNewWindowRelativeToActiveWindow(.file, path, .{
        .subscribed_style_sets = &.{0},
    }, direction, false);
    try FuzzyFinder.hide(self.finder);
}
