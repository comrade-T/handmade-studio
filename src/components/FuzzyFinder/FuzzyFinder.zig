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

const FuzzyFinder = @This();
const std = @import("std");
const fuzzig = @import("fuzzig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const RenderMall = @import("RenderMall");
const ip = @import("input_processor");
const code_point = @import("code_point");
const WindowManager = @import("WindowManager");
const AnchorPicker = @import("AnchorPicker");
const DepartmentOfInputs = @import("DepartmentOfInputs");
const utils = @import("path_getters.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

const NORMAL = "normal";
const FI = "fuzzy_finder_insert";

const NORMAL_TO_FI = ip.Callback.Contexts{ .remove = &.{NORMAL}, .add = &.{FI} };
const FI_TO_NORMAL = ip.Callback.Contexts{ .remove = &.{FI}, .add = &.{NORMAL} };

pub fn mapKeys(ff: *@This(), c: *ip.MappingCouncil) !void {

    // mode enter & exit
    try c.map(FI, &.{.escape}, .{ .f = FuzzyFinder.hide, .ctx = ff, .contexts = FI_TO_NORMAL });
    try c.map(NORMAL, &.{ .left_control, .f }, .{ .f = FuzzyFinder.show, .ctx = ff, .contexts = NORMAL_TO_FI, .require_clarity_afterwards = true });

    try c.map(FI, &.{ .left_control, .j }, .{ .f = nextItem, .ctx = ff });
    try c.map(FI, &.{ .left_control, .k }, .{ .f = prevItem, .ctx = ff });

    // spawn
    const RelativeSpawnCb = struct {
        direction: WindowManager.WindowRelativeDirection,
        target: *FuzzyFinder,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.spawnRelativeToActiveWindow(self.direction);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, direction: WindowManager.WindowRelativeDirection) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*FuzzyFinder, @ptrCast(@alignCast(ctx)));
            self.* = .{ .direction = direction, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .contexts = FI_TO_NORMAL };
        }
    };
    try c.map(FI, &.{ .left_control, .v }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .right));
    try c.map(FI, &.{ .left_control, .left_shift, .v }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .left));
    try c.map(FI, &.{ .left_shift, .left_control, .v }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .left));
    try c.map(FI, &.{ .left_control, .x }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .bottom));
    try c.map(FI, &.{ .left_control, .left_shift, .x }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .top));
    try c.map(FI, &.{ .left_shift, .left_control, .x }, try RelativeSpawnCb.init(c.arena.allocator(), ff, .top));
}

//////////////////////////////////////////////////////////////////////////////////////////////

const PathList = ArrayList([]const u8);
const MatchList = ArrayList(Match);

const Match = struct {
    score: i32,
    matches: []const usize,
    path_index: usize,

    pub fn moreThan(_: void, a: Match, b: Match) bool {
        return a.score > b.score;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
visible: bool = false,

limit: u16 = 100,
selection_index: u16 = 0,

x: f32 = 100,
y: f32 = 100,

path_arena: ArenaAllocator,
match_arena: ArenaAllocator,
path_list: PathList,
match_list: MatchList,

wm: *WindowManager,
ap: *AnchorPicker,

doi: *DepartmentOfInputs,
needle: []const u8 = "",

kind: utils.AppendFileNamesRequest.Kind = .files,

const INPUT_NAME = "fuzzy_finder";

pub fn create(a: Allocator, doi: *DepartmentOfInputs, wm: *WindowManager, ap: *AnchorPicker) !*FuzzyFinder {
    const self = try a.create(@This());
    self.* = FuzzyFinder{
        .a = a,
        .path_arena = ArenaAllocator.init(a),
        .match_arena = ArenaAllocator.init(a),
        .path_list = try PathList.initCapacity(a, 128),
        .match_list = MatchList.init(a),

        .wm = wm,
        .ap = ap,
        .doi = doi,
    };

    assert(try doi.addInput(
        INPUT_NAME,
        .{
            .pos = .{ .x = self.x, .y = self.y },
        },
        .{
            .onUpdate = .{ .ctx = self, .f = update },
            .onConfirm = .{ .ctx = self, .f = confirm },
        },
    ));

    return self;
}

pub fn destroy(self: *@This()) void {
    assert(self.doi.removeInput(INPUT_NAME));
    if (self.needle.len > 0) self.a.free(self.needle);

    self.path_list.deinit();
    self.path_arena.deinit();

    self.match_list.deinit();
    self.match_arena.deinit();

    self.a.destroy(self);
}

pub fn show(ctx: *anyopaque) !void {
    const self = @as(*FuzzyFinder, @ptrCast(@alignCast(ctx)));
    try self.updateFilePaths();
    try update(self, self.needle);
    assert(try self.doi.showInput(INPUT_NAME));
    self.visible = true;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    assert(try self.doi.hideInput(INPUT_NAME));
    try self.doi.council.removeActiveContext(FI);
    try self.doi.council.addActiveContext(NORMAL);
    self.visible = false;
}

pub fn spawnRelativeToActiveWindow(self: *@This(), direction: WindowManager.WindowRelativeDirection) !void {
    assert(self.selection_index <= self.match_list.items.len -| 1);
    const match = self.match_list.items[self.selection_index];
    const path = self.path_list.items[match.path_index];

    try self.wm.spawnNewWindowRelativeToActiveWindow(.file, path, .{
        .subscribed_style_sets = &.{0},
    }, direction);

    try hide(self);
}

pub fn nextItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.selection_index = @min(self.match_list.items.len -| 1, self.selection_index + 1);
}

pub fn prevItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.selection_index -|= 1;
}

fn keepSelectionIndexInBound(self: *@This()) void {
    self.selection_index = @min(self.match_list.items.len -| 1, self.selection_index);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn render(self: *const @This()) void {
    if (!self.visible) return;
    self.renderResults(self.doi.mall.rcb);
}

fn renderResults(self: *const @This(), render_callbacks: RenderMall.RenderCallbacks) void {
    const font = self.doi.mall.font_store.getDefaultFont() orelse unreachable;
    const font_size = 30;
    const default_glyph = font.glyph_map.get('?') orelse unreachable;

    const normal_color = 0xffffffff;
    const match_color = 0xf78c6cff;

    const start_x = self.x;
    const y_distance_from_input = 100;
    const start_y = self.y + y_distance_from_input;

    var x: f32 = start_x;
    var y: f32 = start_y;

    for (self.match_list.items, 0..) |match, i| {
        defer y += font_size;
        defer x = start_x;

        var match_index: usize = 0;
        var cp_index: usize = 0;

        var cp_iter = code_point.Iterator{ .bytes = self.path_list.items[match.path_index] };
        while (cp_iter.next()) |cp| {
            defer cp_index += 1;
            var color: u32 = normal_color;

            pick_color: {
                if (i == self.selection_index) {
                    color = match_color;
                    break :pick_color;
                }
                if (match_index + 1 <= match.matches.len and match.matches[match_index] == cp_index) {
                    color = match_color;
                    match_index += 1;
                }
            }

            const char_width = RenderMall.calculateGlyphWidth(font, font_size, cp.code, default_glyph);
            defer x += char_width;

            render_callbacks.drawCodePoint(font, cp.code, x, y, font_size, color);
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn updateFilePaths(self: *@This()) !void {
    self.path_arena.deinit();
    self.path_arena = ArenaAllocator.init(self.a);
    self.path_list.clearRetainingCapacity();
    try utils.appendFileNamesRelativeToCwd(.{
        .arena = &self.path_arena,
        .sub_path = ".",
        .list = &self.path_list,
        .kind = self.kind,
    });
}

fn cacheNeedle(self: *@This(), needle: []const u8) !void {
    const duped_needle = try self.a.dupe(u8, needle);
    if (self.needle.len > 0) self.a.free(self.needle);
    self.needle = duped_needle;
}

fn update(ctx: *anyopaque, needle: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    defer self.keepSelectionIndexInBound();

    try self.cacheNeedle(needle);

    self.match_arena.deinit();
    self.match_arena = ArenaAllocator.init(self.a);
    self.match_list.clearRetainingCapacity();

    // fuzzig will crash if needle is an empty string
    if (self.needle.len == 0) {
        for (self.path_list.items, 0..) |_, i| {
            if (i >= self.limit) break;
            try self.match_list.append(Match{ .path_index = i, .score = 0, .matches = &.{} });
        }
        return;
    }

    var searcher = try fuzzig.Ascii.init(self.match_arena.allocator(), 1024 * 4, 1024, .{ .case_sensitive = false });
    defer searcher.deinit();

    for (self.path_list.items, 0..) |path, i| {
        if (i >= self.limit) break;

        const match = searcher.scoreMatches(path, self.needle);
        if (match.score) |score| try self.match_list.append(Match{
            .path_index = i,
            .score = score,
            .matches = try self.match_arena.allocator().dupe(usize, match.matches),
        });
    }

    std.mem.sort(Match, self.match_list.items, {}, Match.moreThan);
}

fn confirm(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    assert(self.selection_index <= self.match_list.items.len -| 1);
    const match = self.match_list.items[self.selection_index];
    const path = self.path_list.items[match.path_index];

    const x, const y = self.doi.mall.icb.getScreenToWorld2D(
        self.doi.mall.camera,
        self.ap.target_anchor.x,
        self.ap.target_anchor.y,
    );

    try self.wm.spawnWindow(.file, path, .{
        .pos = .{ .x = x, .y = y },
        .subscribed_style_sets = &.{0},
    }, true, true);

    try hide(self);
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(utils);
}
