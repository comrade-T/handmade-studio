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
const DepartmentOfInputs = @import("DepartmentOfInputs");
const utils = @import("path_getters.zig");
const ConfirmationPrompt = @import("ConfirmationPrompt");
const NotificationLine = @import("NotificationLine");

////////////////////////////////////////////////////////////////////////////////////////////// Public

a: Allocator,

limit: u16 = 100,
selection_index: u16 = 0,
x: f32 = 100,
y: f32 = 100,

entry_arena: ArenaAllocator,
match_arena: ArenaAllocator,
entry_list: PathWithStatsList,
match_list: MatchList,

doi: *DepartmentOfInputs,
needle: []const u8 = "",

opts: FuzzyFinderCreateOptions,
fresh: bool = true,

progress: RenderMall.Progress = .{ .delta = 15 },

reset_selection_index: enum { yes, no } = .yes,

pub fn mapKeys(self: *@This()) !void {
    const c = self.doi.council;
    const ctx_id = self.opts.input_name;
    try c.map(ctx_id, &.{ .left_control, .j }, .{ .f = nextItem, .ctx = self });
    try c.map(ctx_id, &.{ .left_control, .k }, .{ .f = prevItem, .ctx = self });
    try c.map(ctx_id, &.{ .left_alt, .d }, .{ .f = deleteSelectedItemWithConfirmationPrompt, .ctx = self });
    try c.map(ctx_id, &.{.escape}, .{ .f = hide, .ctx = self });
}

pub fn create(a: Allocator, doi: *DepartmentOfInputs, opts: FuzzyFinderCreateOptions) !*FuzzyFinder {
    const self = try a.create(@This());
    self.* = FuzzyFinder{
        .a = a,
        .entry_arena = ArenaAllocator.init(a),
        .match_arena = ArenaAllocator.init(a),
        .entry_list = try PathWithStatsList.initCapacity(a, 128),
        .match_list = MatchList.init(a),
        .doi = doi,
        .opts = opts,
    };

    assert(try doi.addInput(
        self.opts.input_name,
        .{
            .absolute = true,
            .pos = .{ .x = self.x, .y = self.y },
        },
        .{
            .onUpdate = .{ .ctx = self, .f = update },
            .onConfirm = .{ .ctx = self, .f = confirm },
        },
    ));

    try self.mapKeys();

    return self;
}

pub fn destroy(self: *@This()) void {
    assert(self.doi.removeInput(self.opts.input_name));
    if (self.needle.len > 0) self.a.free(self.needle);

    self.entry_list.deinit();
    self.entry_arena.deinit();

    self.match_list.deinit();
    self.match_arena.deinit();

    self.a.destroy(self);
}

pub fn show(ctx: *anyopaque) !void {
    const self = @as(*FuzzyFinder, @ptrCast(@alignCast(ctx)));
    defer self.fresh = false;

    self.reset_selection_index = .no;
    try self.refreshEntries();

    assert(try self.doi.showInput(self.opts.input_name));

    if (self.opts.onShow) |cb| try cb.f(cb.ctx, self.needle);

    self.progress.mode = .in;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    assert(try self.doi.hideInput(self.opts.input_name));
    if (self.opts.onHide) |onHide| try onHide.f(onHide.ctx, self.needle);
    self.progress.mode = .out;
}

pub fn nextItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.selection_index = @min(self.match_list.items.len -| 1, self.selection_index + 1);
}

pub fn prevItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.selection_index -|= 1;
}

pub fn getSelectedPath(self: *@This()) ?[]const u8 {
    if (self.match_list.items.len == 0) return null;
    assert(self.selection_index <= self.match_list.items.len -| 1);
    const match = self.match_list.items[self.selection_index];
    const entry = self.entry_list.items[match.entry_index];
    return entry.path;
}

pub fn getSelectedIndex(self: *@This()) ?usize {
    if (self.match_list.items.len == 0) return null;
    assert(self.selection_index <= self.match_list.items.len -| 1);
    const match = self.match_list.items[self.selection_index];
    return match.entry_index;
}

pub fn addEntryUnmanaged(self: *@This(), entry: []const u8) !void {
    try self.entry_list.append(.{ .path = entry, .mtime = std.time.nanoTimestamp() });
}

pub fn addEntry(self: *@This(), path: []const u8) !void {
    const duped_path = try self.entry_arena.allocator().dupe(u8, path);
    try self.entry_list.append(.{ .path = duped_path, .mtime = std.time.nanoTimestamp() });
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn deleteSelectedItemWithConfirmationPrompt(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.getSelectedPath() orelse return;
    const msg = try std.fmt.allocPrint(self.a, "Are you sure you want to delete '{s}'? (y / n)", .{path});
    defer self.a.free(msg);
    if (self.opts.cp) |cp| {
        try cp.show(msg, .{ .onConfirm = .{ .f = deleteSelectedItem, .ctx = self } });
    }
}

fn deleteSelectedItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.getSelectedPath() orelse return;

    const duped_path = try self.a.dupe(u8, path);
    defer self.a.free(duped_path);

    try std.fs.cwd().deleteTree(path);

    self.reset_selection_index = .no;
    try self.updateEntries();
    try update(self, self.needle);
    self.keepSelectionIndexInBound();

    const msg = try std.fmt.allocPrint(self.a, "'{s}' has been deleted", .{duped_path});
    defer self.a.free(msg);
    if (self.opts.nl) |nl| try nl.setMessage(msg);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

const progressAlphaChannel = RenderMall.ColorschemeStore.progressAlphaChannel;

pub fn render(self: *@This()) !void {
    self.progress.update();
    self.renderFadingGradientBackground();
    if (self.progress.value > 0) self.renderResults(self.doi.mall);
    if (self.opts.postRender) |cb| try cb.f(cb.ctx, self.needle);
}

fn renderFadingGradientBackground(self: *@This()) void {
    const width, const height = self.doi.mall.icb.getScreenWidthHeight();
    self.doi.mall.rcb.drawRectangleGradient(
        0,
        0,
        width,
        height,
        progressAlphaChannel(0x000000ff, self.progress.value),
        progressAlphaChannel(0x000000aa, self.progress.value),
        progressAlphaChannel(0x00000099, self.progress.value),
        progressAlphaChannel(0x000000ff, self.progress.value),
    );
}

fn renderResults(self: *const @This(), mall: *const RenderMall) void {
    var renderer = Renderer.init(self, mall);
    renderer.render(mall);
}

const Renderer = struct {
    finder: *const FuzzyFinder,

    font: *const RenderMall.FontStore.Font = undefined,
    default_glyph: RenderMall.FontStore.Font.GlyphData = undefined,

    start_x: f32 = undefined,
    start_y: f32 = undefined,

    x: f32 = undefined,
    y: f32 = undefined,

    match_color: u32 = undefined,
    entry_color: u32 = undefined,

    const X_ANIMATION_MOVE_DISTANCE = 20;
    const Y_DISTANCE_FROM_INPUT = 100;
    const ENTRY_FONTSIZE = 30;
    const DEFAULT_ENTRY_COLOR = 0xffffffff;

    fn init(finder: *const FuzzyFinder, mall: *const RenderMall) Renderer {
        var self = Renderer{ .finder = finder };
        self.font = mall.font_store.getDefaultFont() orelse unreachable;
        self.default_glyph = self.font.glyph_map.get('?') orelse unreachable;

        self.start_x = self.finder.x - X_ANIMATION_MOVE_DISTANCE;
        self.start_y = self.finder.y + Y_DISTANCE_FROM_INPUT;
        self.x = self.getAnimatedX();
        self.y = self.start_y;

        return self;
    }

    fn getStartEntryIndexToRender(self: *const @This(), screen_height: f32) usize {
        const half_of_entry_zone_height = (screen_height - self.start_y) / 2;
        var accumulated_height: f32 = 0;

        var i: usize = self.finder.selection_index + 1;
        while (i > 0) {
            i -= 1;
            if (accumulated_height > half_of_entry_zone_height) break;
            const match = self.finder.match_list.items[i];
            const match_contents = self.finder.entry_list.items[match.entry_index].path;
            const match_line_count = std.mem.count(u8, match_contents, "\n") + 1;
            accumulated_height += @as(f32, @floatFromInt(match_line_count)) * ENTRY_FONTSIZE + self.finder.opts.y_distance_between_entries;
            if (accumulated_height > half_of_entry_zone_height) return i;
        }

        return 0;
    }

    fn render(self: *@This(), mall: *const RenderMall) void {
        _, const screen_height = mall.icb.getScreenWidthHeight();
        if (self.finder.match_list.items.len == 0) return;

        self.match_color = progressAlphaChannel(0xf78c6cff, self.finder.progress.value);

        for (self.getStartEntryIndexToRender(screen_height)..self.finder.match_list.items.len) |i| {
            if (self.y + ENTRY_FONTSIZE > screen_height) break;

            const match = self.finder.match_list.items[i];
            self.updateEntryColor(match);

            const y_before_rendering_this_line = self.y;
            defer self.renderVeritcalLine(mall, y_before_rendering_this_line, i);

            defer self.y += ENTRY_FONTSIZE + self.finder.opts.y_distance_between_entries;
            defer self.x = self.getAnimatedX();

            self.renderEntry(mall, match, i);
        }
    }

    fn renderEntry(self: *@This(), mall: *const RenderMall, match: Match, i: usize) void {
        var match_index: usize = 0;
        var cp_index: usize = 0;

        var cp_iter = code_point.Iterator{ .bytes = self.finder.entry_list.items[match.entry_index].path };
        while (cp_iter.next()) |cp| {
            defer cp_index += 1;

            var char_color: u32 = self.entry_color;

            pick_color: {
                if (i == self.finder.selection_index and self.finder.opts.fill_selected_entry_with_matched_color) {
                    char_color = self.match_color;
                    break :pick_color;
                }
                if (match_index + 1 <= match.matches.len and match.matches[match_index] == cp_index) {
                    char_color = self.match_color;
                    match_index += 1;
                }
            }

            if (cp.code == '\n') {
                self.y += ENTRY_FONTSIZE;
                self.x = self.getAnimatedX();
                continue;
            }

            const char_width = RenderMall.calculateGlyphWidth(self.font, ENTRY_FONTSIZE, cp.code, self.default_glyph);
            defer self.x += char_width;

            mall.rcb.drawCodePoint(self.font, cp.code, self.x, self.y, ENTRY_FONTSIZE, char_color);
        }
    }

    const VERTICAL_LINE_THICKNESS = 3;
    const VERTICAL_LINE_OFFSET = 10;
    fn renderVeritcalLine(self: *const @This(), mall: *const RenderMall, y_before_rendering_this_line: f32, i: usize) void {
        if (i == self.finder.selection_index and self.finder.opts.render_vertical_line_at_selected_entry) {
            const color = if (self.finder.opts.getEntryColor != null) self.entry_color else self.match_color;
            const x_ = self.x - VERTICAL_LINE_OFFSET;
            mall.rcb.drawLine(
                x_,
                y_before_rendering_this_line,
                x_,
                self.y - self.finder.opts.y_distance_between_entries,
                VERTICAL_LINE_THICKNESS,
                color,
            );
        }
    }

    fn updateEntryColor(self: *@This(), match: Match) void {
        var color: u32 = DEFAULT_ENTRY_COLOR;
        if (self.finder.opts.getEntryColor) |cb| color = cb.f(cb.ctx, match.entry_index) catch DEFAULT_ENTRY_COLOR;
        color = progressAlphaChannel(color, self.finder.progress.value);
        self.entry_color = color;
    }

    fn getAnimatedX(self: *const @This()) f32 {
        return self.start_x + (X_ANIMATION_MOVE_DISTANCE * @as(f32, @floatFromInt(self.finder.progress.value)) / 100);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Internal

fn update(ctx: *anyopaque, new_needle: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    defer self.reset_selection_index = .yes;
    try self.updateInternal(new_needle);
    if (self.opts.onUpdate) |onUpdate| try onUpdate.f(onUpdate.ctx, self.needle);
    if (self.reset_selection_index == .yes) self.selection_index = 0;
}

fn updateInternal(self: *@This(), new_needle: []const u8) !void {
    defer self.keepSelectionIndexInBound();
    try self.cacheNeedle(new_needle);

    self.match_arena.deinit();
    self.match_arena = ArenaAllocator.init(self.a);
    self.match_list.clearRetainingCapacity();

    // fuzzig will crash if needle is an empty string
    if (self.needle.len == 0) {
        for (self.entry_list.items, 0..) |entry, i| {
            if (i >= self.limit) break;
            try self.match_list.append(Match{
                .entry_index = i,
                .score = 0,
                .matches = &.{},
                .mtime = entry.mtime,
            });
        }
        switch (self.opts.sort_by_mtime) {
            .nope => {},
            .initially => if (self.fresh) self.sortMatchListByMTime(),
            .on_empty_needle => self.sortMatchListByMTime(),
        }
        return;
    }

    var searcher = try fuzzig.Ascii.init(self.match_arena.allocator(), 1024 * 4, 1024, .{ .case_sensitive = false });
    defer searcher.deinit();

    for (self.entry_list.items, 0..) |entry, i| {
        if (i >= self.limit) break;

        const match = searcher.scoreMatches(entry.path, self.needle);
        if (match.score) |score| try self.match_list.append(Match{
            .entry_index = i,
            .score = score,
            .matches = try self.match_arena.allocator().dupe(usize, match.matches),
            .mtime = entry.mtime,
        });
    }

    std.mem.sort(Match, self.match_list.items, {}, Match.moreThan);
}

fn sortMatchListByMTime(self: *@This()) void {
    std.mem.sort(Match, self.match_list.items, {}, Match.sortByMTime);
}

fn confirm(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.opts.onConfirm) |onConfirm| {
        if (try onConfirm.f(onConfirm.ctx, self.needle)) {
            try hide(self);
        }
    }
}

pub fn refreshEntries(self: *@This()) !void {
    try self.updateEntries();
    try update(self, self.needle);
}

fn updateEntries(self: *@This()) !void {
    self.entry_arena.deinit();
    self.entry_arena = ArenaAllocator.init(self.a);
    self.entry_list.clearRetainingCapacity();

    if (self.opts.updater) |cb| {
        try cb.f(cb.ctx, self.needle);
        return;
    }
    try self.updateFilePaths();
}

fn updateFilePaths(self: *@This()) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var final_ignore_list = ArrayList([]const u8).init(arena.allocator());
    defer arena.deinit();

    const git_ignore_patterns = self.opts.custom_ignore_patterns orelse
        try utils.getGitIgnorePatternsOfCWD(arena.allocator());

    if (self.opts.ignore_ignore_patterns) |ignore_ignore_patterns| {
        for (git_ignore_patterns) |pattern| {
            var ignored = false;
            for (ignore_ignore_patterns) |ignore_pattern| {
                if (std.mem.eql(u8, pattern, ignore_pattern)) {
                    ignored = true;
                    break;
                }
            }
            if (!ignored) try final_ignore_list.append(pattern);
        }
    }

    try utils.appendFileNamesRelativeToCwd(.{
        .arena = &self.entry_arena,
        .sub_path = ".",
        .list = null,
        .kind = self.opts.kind,
        .ignore_patterns = if (self.opts.ignore_ignore_patterns != null)
            final_ignore_list.items
        else
            git_ignore_patterns,
        .match_patterns = self.opts.custom_match_patterns,

        .with_stats = true,
        .list_with_stats = &self.entry_list,
    });
}

fn cacheNeedle(self: *@This(), needle: []const u8) !void {
    const duped_needle = try self.a.dupe(u8, needle);
    if (self.needle.len > 0) self.a.free(self.needle);
    self.needle = duped_needle;
}

fn keepSelectionIndexInBound(self: *@This()) void {
    self.selection_index = @min(self.match_list.items.len -| 1, self.selection_index);
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const PathWithStatsList = ArrayList(utils.AppendFileNamesRequest.PathWithStats);
const MatchList = ArrayList(Match);

const Match = struct {
    score: i32,
    matches: []const usize,
    entry_index: usize,
    mtime: i128,

    pub fn moreThan(_: void, a: Match, b: Match) bool {
        return a.score > b.score;
    }

    pub fn sortByMTime(_: void, a: Match, b: Match) bool {
        return a.mtime > b.mtime;
    }
};

/////////////////////////////

const FuzzyFinderCreateOptions = struct {
    cp: ?*ConfirmationPrompt = null,
    nl: ?*NotificationLine = null,

    input_name: []const u8,
    kind: utils.AppendFileNamesRequest.Kind = .files,

    onUpdate: ?Callback = null,
    onConfirm: ?BoolCallback = null,
    onCancel: ?Callback = null,
    onHide: ?Callback = null,
    onShow: ?Callback = null,

    updater: ?Callback = null,
    postRender: ?Callback = null,
    getEntryColor: ?GetEntryColorCallback = null,
    y_distance_between_entries: f32 = 0,

    fill_selected_entry_with_matched_color: bool = true,
    render_angle_bracket_at_selected_entry: bool = false,
    render_vertical_line_at_selected_entry: bool = false,

    custom_ignore_patterns: ?[]const []const u8 = null,
    ignore_ignore_patterns: ?[]const []const u8 = null,
    custom_match_patterns: ?[]const []const u8 = null,

    sort_by_mtime: enum { nope, initially, on_empty_needle } = .nope,
};

pub const Callback = struct {
    f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!void,
    ctx: *anyopaque,
};

pub const GetEntryColorCallback = struct {
    f: *const fn (ctx: *anyopaque, index: usize) anyerror!u32,
    ctx: *anyopaque,
};

pub const BoolCallback = struct {
    f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!bool,
    ctx: *anyopaque,
};
