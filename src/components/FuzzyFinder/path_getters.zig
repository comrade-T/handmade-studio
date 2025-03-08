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

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;

const fuzzig = @import("fuzzig");

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
