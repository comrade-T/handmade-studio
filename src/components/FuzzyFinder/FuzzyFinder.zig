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
visible: bool = false,

limit: u16 = 100,
selection_index: u16 = 0,
x: f32 = 100,
y: f32 = 100,

entry_arena: ArenaAllocator,
match_arena: ArenaAllocator,
entry_list: PathList,
match_list: MatchList,

doi: *DepartmentOfInputs,
needle: []const u8 = "",

opts: FuzzyFinderCreateOptions,

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
        .entry_list = try PathList.initCapacity(a, 128),
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
    try self.updateEntries();
    try update(self, self.needle);
    assert(try self.doi.showInput(self.opts.input_name));
    self.visible = true;
}

pub fn hide(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    assert(try self.doi.hideInput(self.opts.input_name));
    if (self.opts.onHide) |onHide| try onHide.f(onHide.ctx, self.needle);
    self.visible = false;
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
    const path = self.entry_list.items[match.entry_index];
    return path;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn deleteSelectedItemWithConfirmationPrompt(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.getSelectedPath() orelse return;
    const msg = try std.fmt.allocPrint(self.a, "Are you sure you want to delete '{s}'? (y / n)", .{path});
    defer self.a.free(msg);
    try self.opts.cp.show(msg, .{ .onConfirm = .{ .f = deleteSelectedItem, .ctx = self } });
}

fn deleteSelectedItem(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const path = self.getSelectedPath() orelse return;

    const duped_path = try self.a.dupe(u8, path);
    defer self.a.free(duped_path);

    try std.fs.cwd().deleteTree(path);

    try self.updateEntries();
    try update(self, self.needle);
    self.keepSelectionIndexInBound();

    const msg = try std.fmt.allocPrint(self.a, "'{s}' has been deleted", .{duped_path});
    defer self.a.free(msg);
    try self.opts.nl.setMessage(msg);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

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

        var cp_iter = code_point.Iterator{ .bytes = self.entry_list.items[match.entry_index] };
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

////////////////////////////////////////////////////////////////////////////////////////////// Internal

fn update(ctx: *anyopaque, new_needle: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.updateInternal(new_needle);
    if (self.opts.onUpdate) |onUpdate| try onUpdate.f(onUpdate.ctx, self.needle);
}

fn updateInternal(self: *@This(), new_needle: []const u8) !void {
    defer self.keepSelectionIndexInBound();
    try self.cacheNeedle(new_needle);

    self.match_arena.deinit();
    self.match_arena = ArenaAllocator.init(self.a);
    self.match_list.clearRetainingCapacity();

    // fuzzig will crash if needle is an empty string
    if (self.needle.len == 0) {
        for (self.entry_list.items, 0..) |_, i| {
            if (i >= self.limit) break;
            try self.match_list.append(Match{ .entry_index = i, .score = 0, .matches = &.{} });
        }
        return;
    }

    var searcher = try fuzzig.Ascii.init(self.match_arena.allocator(), 1024 * 4, 1024, .{ .case_sensitive = false });
    defer searcher.deinit();

    for (self.entry_list.items, 0..) |entry, i| {
        if (i >= self.limit) break;

        const match = searcher.scoreMatches(entry, self.needle);
        if (match.score) |score| try self.match_list.append(Match{
            .entry_index = i,
            .score = score,
            .matches = try self.match_arena.allocator().dupe(usize, match.matches),
        });
    }

    std.mem.sort(Match, self.match_list.items, {}, Match.moreThan);
}

fn confirm(ctx: *anyopaque, _: []const u8) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.opts.onConfirm) |onConfirm| {
        if (try onConfirm.f(onConfirm.ctx, self.needle)) {
            try hide(self);
        }
    }
}

fn updateEntries(self: *@This()) !void {
    if (self.opts.updateEntries) |cb| {
        try cb.f(cb.ctx, self.needle);
        return;
    }
    try self.updateFilePaths();
}

fn updateFilePaths(self: *@This()) !void {
    self.entry_arena.deinit();
    self.entry_arena = ArenaAllocator.init(self.a);
    self.entry_list.clearRetainingCapacity();

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
        .list = &self.entry_list,
        .kind = self.opts.kind,
        .ignore_patterns = if (self.opts.ignore_ignore_patterns != null)
            final_ignore_list.items
        else
            git_ignore_patterns,
        .match_patterns = self.opts.custom_match_patterns,
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

const PathList = ArrayList([]const u8);
const MatchList = ArrayList(Match);

const Match = struct {
    score: i32,
    matches: []const usize,
    entry_index: usize,

    pub fn moreThan(_: void, a: Match, b: Match) bool {
        return a.score > b.score;
    }
};

/////////////////////////////

const FuzzyFinderCreateOptions = struct {
    cp: *ConfirmationPrompt,
    nl: *NotificationLine,

    input_name: []const u8,
    kind: utils.AppendFileNamesRequest.Kind,

    onUpdate: ?Callback = null,
    onConfirm: ?BoolCallback = null,
    onCancel: ?Callback = null,
    onHide: ?Callback = null,
    onShow: ?Callback = null,

    updateEntries: ?Callback = null,

    custom_ignore_patterns: ?[]const []const u8 = null,
    ignore_ignore_patterns: ?[]const []const u8 = null,
    custom_match_patterns: ?[]const []const u8 = null,
};

pub const Callback = struct {
    f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!void,
    ctx: *anyopaque,
};

const BoolCallback = struct {
    f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!bool,
    ctx: *anyopaque,
};

//////////////////////////////////////////////////////////////////////////////////////////////
