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
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const RenderMall = @import("RenderMall");
const ip = @import("input_processor");
const code_point = @import("code_point");
const WindowManager = @import("WindowManager");
const AnchorPicker = @import("AnchorPicker");
const DepartmentOfInputs = @import("DepartmentOfInputs");

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

    try self.updateFilePaths();

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
    try appendFileNamesRelativeToCwd(&self.path_arena, ".", &self.path_list, true);
}

fn update(ctx: *anyopaque, needle: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    defer self.keepSelectionIndexInBound();

    if (self.needle.len > 0) {
        self.a.free(self.needle);
        self.needle = try self.a.dupe(u8, needle);
    }

    self.match_arena.deinit();
    self.match_arena = ArenaAllocator.init(self.a);
    self.match_list.clearRetainingCapacity();

    // fuzzig will crash if needle is an empty string
    if (needle.len == 0) {
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

        const match = searcher.scoreMatches(path, needle);
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

fn getGitIgnorePatternsOfCWD(a: Allocator) !ArrayList([]const u8) {
    var cwd_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer cwd_dir.close();
    errdefer cwd_dir.close();

    const file = try cwd_dir.openFile(".gitignore", .{ .mode = .read_only });
    errdefer file.close();
    defer file.close();

    const stat = try file.stat();

    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);

    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    var patterns_list = std.ArrayList([]const u8).init(a);
    errdefer patterns_list.deinit();
    try patterns_list.append(".git/");

    var iter = std.mem.split(u8, buf, "\n");
    while (iter.next()) |pattern| try patterns_list.append(pattern);
    return patterns_list;
}

pub fn appendFileNamesRelativeToCwd(arena: *ArenaAllocator, sub_path: []const u8, list: *ArrayList([]const u8), recursive: bool) !void {
    const patterns = try getGitIgnorePatternsOfCWD(arena.allocator());

    var dir = try std.fs.cwd().openDir(sub_path, .{ .iterate = true });
    defer dir.close();
    errdefer dir.close();

    var iter = dir.iterate();
    iter_loop: while (try iter.next()) |entry| {
        const short_path = if (entry.kind == .directory)
            try std.fmt.allocPrint(arena.allocator(), "{s}/", .{entry.name})
        else
            try std.fmt.allocPrint(arena.allocator(), "{s}", .{entry.name});

        const relative_path = if (std.mem.eql(u8, sub_path, "."))
            short_path
        else
            try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ sub_path, short_path });

        for (patterns.items) |pattern| if (matchGlob(pattern, relative_path)) continue :iter_loop;
        if (relative_path.len == 0) continue;

        if (entry.kind == .file) try list.append(relative_path);
        if (recursive and entry.kind == .directory) try appendFileNamesRelativeToCwd(arena, relative_path, list, true);
    }
}

// test appendFileNamesRelativeToCwd {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     var list = ArrayList([]const u8).init(arena.allocator());
//     defer list.deinit();
//     {
//         try appendFileNamesRelativeToCwd(&arena, ".", &list, true);
//         for (list.items) |file_name| {
//             std.debug.print("{s}\n", .{file_name});
//         }
//     }
// }

////////////////////////////////////////////////////////////////////////////////////////////// matchGlob

// https://ziggit.dev/t/how-do-i-match-glob-patterns-in-zig/4769
fn matchGlob(pattern: []const u8, source: []const u8) bool {
    if (std.mem.eql(u8, pattern, source)) return true;
    if (pattern.len > 0 and std.mem.startsWith(u8, source, pattern)) return true;

    var pattern_i: usize = 0;
    var source_i: usize = 0;
    var next_pattern_i: usize = 0;
    var next_source_i: usize = 0;

    while (pattern_i < pattern.len or source_i < source.len) {
        if (pattern_i < pattern.len) {
            const c = pattern[pattern_i];
            switch (c) {
                '?' => {
                    if (source_i < source.len) {
                        pattern_i += 1;
                        source_i += 1;
                        continue;
                    }
                },
                '*' => {
                    next_pattern_i = pattern_i;
                    next_source_i = source_i + 1;
                    pattern_i += 1;
                    continue;
                },
                else => {
                    if (source_i < source.len and source[source_i] == c) {
                        pattern_i += 1;
                        source_i += 1;
                        continue;
                    }
                },
            }
        }

        if (next_source_i > 0 and next_source_i <= source.len) {
            pattern_i = next_pattern_i;
            source_i = next_source_i;
            continue;
        }
        return false;
    }

    return true;
}

test "match" {
    try eq(false, matchGlob("", ".git/"));

    try eq(true, matchGlob(".git/", ".git/"));
    try eq(false, matchGlob(".git/", ".gitignore"));

    try eq(true, matchGlob("dummy*.txt", "dummy-A.txt"));
    try eq(false, matchGlob("dummy*.txt", "dummy-A.png"));

    try eq(true, matchGlob("copied-libs/", "copied-libs/"));
    try eq(true, matchGlob("copied-libs/", "copied-libs/dummy.txt"));

    try eq(true, matchGlob("copied-libs/ztracy", "copied-libs/ztracy"));

    try eq(true, matchGlob(".zig-cache/", ".zig-cache/"));
    try eq(true, matchGlob(".zig-cache/", ".zig-cache/dummy.txt"));
}

////////////////////////////////////////////////////////////////////////////////////////////// get file names and fuzzy find over them

const SortScoresCtx = struct {
    scores: []i32,

    pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
        return ctx.scores[a_index] < ctx.scores[b_index];
    }
};

test "get file names and fuzzy find over them" {
    var searcher = try fuzzig.Ascii.init(testing_allocator, 1024 * 4, 1024, .{ .case_sensitive = false });
    defer searcher.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        var paths = ArrayList([]const u8).init(arena.allocator());
        defer paths.deinit();
        try appendFileNamesRelativeToCwd(&arena, ".", &paths, true);

        var match_score_list = std.AutoArrayHashMap(i32, []const u8).init(testing_allocator);
        defer match_score_list.deinit();

        const needle = "rope";
        for (paths.items) |path| {
            const match = searcher.scoreMatches(path, needle);
            if (match.score) |score| try match_score_list.put(score, path);
        }

        match_score_list.sort(SortScoresCtx{ .scores = match_score_list.keys() });

        var i: usize = match_score_list.values().len;
        while (i > 0) {
            i -= 1;
            std.debug.print("path: '{s}' -> score: {d}\n", .{
                match_score_list.values()[i],
                match_score_list.keys()[i],
            });
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Trying out fuzzig

test fuzzig {
    var searcher = try fuzzig.Ascii.init(
        testing_allocator,
        128, // haystack max size
        32, // needle max size
        .{ .case_sensitive = false },
    );
    defer searcher.deinit();

    const match = searcher.scoreMatches("Hello World", "world");
    try eq(104, match.score.?);
    try std.testing.expectEqualSlices(usize, &.{ 6, 7, 8, 9, 10 }, match.matches);
}
