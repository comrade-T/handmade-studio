const std = @import("std");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

fn getPatterns(a: Allocator, dir: std.fs.Dir) [][]const u8 {
    const file = dir.openFile(".gitignore", .{ .mode = .read_only }) catch |err| {
        std.log.err("Unable to open .gitignore: {s}\n", .{@typeName(@TypeOf(err))});
        return &.{};
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        std.log.err("Unable to get stat for .gitignore: {s}\n", .{@typeName(@TypeOf(err))});
        return &.{};
    };
    const buf = a.alloc(u8, stat.size) catch {
        std.log.err("Unable to allocate memory for .gitignore", .{});
        return &.{};
    };
    const read_size = file.reader().read(buf) catch |err| {
        std.log.err("Read error: {s}\n", .{@typeName(@TypeOf(err))});
        return &.{};
    };
    if (read_size != stat.size) {
        std.log.err("Buffer underrun!", .{});
        return &.{};
    }
    const final_read = file.reader().read(buf) catch |err| {
        std.log.err("Final read error: {s}\n", .{@typeName(@TypeOf(err))});
        return &.{};
    };
    if (final_read != 0) {
        std.log.err("unexpected data in final read\n", .{});
        return &.{};
    }

    var patterns = std.ArrayList([]const u8).init(a);
    patterns.append(".git/") catch {};

    var iter = std.mem.split(u8, buf, "\n");
    while (iter.next()) |pattern| {
        if (pattern.len == 0) continue;
        patterns.append(pattern) catch |err| {
            std.log.err("Error appending pattern '{s}': {s}\n", .{ pattern, @typeName(@TypeOf(err)) });
            continue;
        };
    }
    return patterns.toOwnedSlice() catch &.{};
}

pub fn getFileNamesRelativeToCwd(a: Allocator, sub_path: []const u8) [][]const u8 {
    var cwd_dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
        std.log.err("Unable to open cwd!", .{});
        return &.{};
    };
    defer cwd_dir.close();

    const patterns = getPatterns(a, cwd_dir);
    var paths = std.ArrayList([]const u8).init(a);

    var dir = std.fs.cwd().openDir(sub_path, .{ .iterate = true }) catch {
        std.log.err("Unable to open sub_path {s}!", .{sub_path});
        return &.{};
    };
    defer dir.close();

    var iter = dir.iterate();
    iter_loop: while (iter.next()) |maybe_entry| {
        const entry = maybe_entry orelse break;

        const short_path = if (entry.kind == .directory)
            std.fmt.allocPrint(a, "{s}/", .{entry.name}) catch continue
        else
            std.fmt.allocPrint(a, "{s}", .{entry.name}) catch continue;

        const relative_path = if (eql(u8, sub_path, "."))
            short_path
        else
            std.fmt.allocPrint(a, "{s}{s}", .{ sub_path, short_path }) catch continue;

        for (patterns) |p| if (match(p, relative_path)) continue :iter_loop;
        if (relative_path.len == 0) continue;

        paths.append(short_path) catch |err| {
            std.log.err("Error appending path '{s}': {s}\n", .{ short_path, @typeName(@TypeOf(err)) });
            continue;
        };
    } else |err| {
        std.log.err("Error while iterating through directory: {s}\n", .{@typeName(@TypeOf(err))});
    }

    return paths.toOwnedSlice() catch &.{};
}
test getFileNamesRelativeToCwd {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const results = getFileNamesRelativeToCwd(a, ".");
        for (results) |file_name| {
            std.debug.print("{s}\n", .{file_name});
        }
    }
}

// https://ziggit.dev/t/how-do-i-match-glob-patterns-in-zig/4769
fn match(pattern: []const u8, source: []const u8) bool {
    var pattern_i: usize = 0;
    var source_i: usize = 0;
    var next_pattern_i: usize = 0;
    var next_source_i: usize = 0;

    while (pattern_i < pattern.len or source_i < source.len) {
        if (pattern_i < pattern.len) {
            const c = pattern[pattern_i];
            switch (c) {
                '?' => { // single-character wildcard
                    if (source_i < source.len) {
                        pattern_i += 1;
                        source_i += 1;
                        continue;
                    }
                },
                '*' => { // zero-or-more-character wildcard
                    // Try to match at name_i.
                    // If that doesn't work out,
                    // restart at name_i+1 next.
                    next_pattern_i = pattern_i;
                    next_source_i = source_i + 1;
                    pattern_i += 1;
                    continue;
                },
                else => { // ordinary character
                    if (source_i < source.len and source[source_i] == c) {
                        pattern_i += 1;
                        source_i += 1;
                        continue;
                    }
                },
            }
        }

        // Mismatch. Maybe restart.
        if (next_source_i > 0 and next_source_i <= source.len) {
            pattern_i = next_pattern_i;
            source_i = next_source_i;
            continue;
        }
        return false;
    }

    // Matched all of pattern to all of name. Success.
    return true;
}

test "match" {
    try eq(false, match("", ".git/"));

    try eq(true, match(".git/", ".git/"));
    try eq(false, match(".git/", ".gitignore"));

    try eq(true, match("dummy*.txt", "dummy-A.txt"));
    try eq(false, match("dummy*.txt", "dummy-A.png"));
}
