const FuzzyFinder = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

fn getGitIgnorePatterns(a: Allocator, dir: std.fs.Dir) !ArrayList([]const u8) {
    const file = try dir.openFile(".gitignore", .{ .mode = .read_only });
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

pub fn getFileNamesRelativeToCwd(arena: *ArenaAllocator, sub_path: []const u8) !ArrayList([]const u8) {
    var cwd_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer cwd_dir.close();
    errdefer cwd_dir.close();

    const patterns = try getGitIgnorePatterns(arena.allocator(), cwd_dir);

    var paths = std.ArrayList([]const u8).init(arena.allocator());
    errdefer paths.deinit();

    var dir = try std.fs.cwd().openDir(sub_path, .{ .iterate = true });
    defer dir.close();
    errdefer dir.close();

    var iter = dir.iterate();
    iter_loop: while (try iter.next()) |entry| {
        const short_path = if (entry.kind == .directory)
            try std.fmt.allocPrint(arena.allocator(), "{s}/", .{entry.name})
        else
            try std.fmt.allocPrint(arena.allocator(), "{s}", .{entry.name});

        const relative_path = if (eql(u8, sub_path, "."))
            short_path
        else
            try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ sub_path, short_path });

        for (patterns.items) |pattern| if (matchGlob(pattern, relative_path)) continue :iter_loop;
        if (relative_path.len == 0) continue;
        try paths.append(short_path);
    }

    return paths;
}

test getFileNamesRelativeToCwd {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    {
        const results = try getFileNamesRelativeToCwd(&arena, ".");
        for (results.items) |file_name| {
            std.debug.print("{s}\n", .{file_name});
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// matchGlob

// https://ziggit.dev/t/how-do-i-match-glob-patterns-in-zig/4769
fn matchGlob(pattern: []const u8, source: []const u8) bool {
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
}
