const DisplayCachePool = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Buffer = @import("neo_buffer").Buffer;

const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;
const assert = std.debug.assert;

////////////////////////////////////////////////////////////////////////////////////////////// DisplayCachePool

a: Allocator,
buf: *Buffer,

start_line: usize = 0,
end_line: usize = 0,
cached_lines: ArrayList(Line),
default_display: Display,

query_set: ?QuerySet = null,

const InitError = error{OutOfMemory};
pub fn init(a: Allocator, buf: *Buffer, default_display: Display) InitError!*DisplayCachePool {
    const self = try a.create(@This());
    self.* = DisplayCachePool{
        .a = a,
        .buf = buf,
        .cached_lines = ArrayList(Line).init(a),
        .default_display = default_display,
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    for (self.cached_lines.items) |line| {
        self.a.free(line.contents);
        self.a.free(line.displays);
    }
    if (self.query_set) |_| self.query_set.?.deinit();
    self.cached_lines.deinit();
    self.a.destroy(self);
}

pub fn enableQueries(self: *@This(), ids: []const []const u8) !void {
    const langsuite = self.buf.langsuite orelse return;
    const queries = langsuite.queries orelse {
        std.debug.print("hello?\n", .{});
        return;
    };

    if (self.query_set == null) self.query_set = try QuerySet.initCapacity(self.a, ids.len);

    for (ids) |query_id| {
        const sq = queries.get(query_id) orelse {
            std.log.err("query not found for id '{s}'", .{query_id});
            continue;
        };
        try self.query_set.?.append(sq);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// requestLines

const RequestLinesError = error{ OutOfMemory, EndLineOutOfBounds };
pub fn requestLines(self: *@This(), start: usize, end: usize) RequestLinesError![]Line {
    if (end > self.getLastLineNumberOfBuffer()) return RequestLinesError.EndLineOutOfBounds;

    assert(start <= end);

    // cache empty
    if (self.cached_lines.items.len == 0) {
        try self.createAndAppendLinesWithDefaultDisplays(start, end);
        self.setStartAndEndLine(start, end);
        try self.applyTreeSitterToDisplays(start, end);
        return self.cached_lines.items;
    }

    // requested range already cached
    if (start >= self.start_line and end <= self.end_line) {
        return self.cached_lines.items[start .. end + 1];
    }

    if (start < self.start_line) {
        const edit_end = self.start_line - 1;
        const new_lines_list = try self.createDefaultLinesList(start, edit_end);
        defer new_lines_list.deinit();
        try self.cached_lines.insertSlice(0, new_lines_list.items);
        self.setStartAndEndLine(start, self.end_line);

        try self.applyTreeSitterToDisplays(start, edit_end);
    }

    if (end > self.end_line) {
        const edit_start = self.end_line + 1;
        try self.createAndAppendLinesWithDefaultDisplays(edit_start, end);
        self.setStartAndEndLine(self.start_line, end);

        try self.applyTreeSitterToDisplays(edit_start, end);
    }

    return self.cached_lines.items[(start - self.start_line)..(end - self.start_line + 1)];
}

test "requestLines - with tree sitter" {
    {
        const lsuite, const buf, const dcp = try setupTestDependencies();
        defer cleanUpTestDependencies(lsuite, buf, dcp);

        // request first 5 lines
        try requestAndTestLines(.{ 0, 4 }, dcp, .{ 0, 4 },
            \\const std = @import("std"); // 0
            \\qqqqq vvv d iiiiiiipssssspp cc c
            \\const Allocator = std.mem.Allocator; // 1
            \\qqqqq ttttttttt d vvvpfffptttttttttp cc c
            \\// 2
            \\cc c
            \\fn add(x: f32, y: f32) void { // 3
            \\kk FFFpPp tttp Pp tttp tttt p cc c
            \\    return x + y; // 4
            \\    dddddd v o vp cc c
        );

        // request lines that are already cached (> 0 and <= 4)
        {
            try requestAndTestLines(.{ 0, 1 }, dcp, .{ 0, 4 },
                \\const std = @import("std"); // 0
                \\qqqqq vvv d iiiiiiipssssspp cc c
                \\const Allocator = std.mem.Allocator; // 1
                \\qqqqq ttttttttt d vvvpfffptttttttttp cc c
            );
        }

        // request lines that are not cached - after `DisplayCachePool.end_line` (> 4)
        {
            try requestAndTestLines(.{ 11, 14 }, dcp, .{ 0, 14 },
                \\pub const not_false = true; // 11
                \\kkk qqqqq vvvvvvvvv d bbbbp cc cc
                \\// 12
                \\cc cc
                \\var xxx = 0; // 13
                \\qqq vvv d np cc cc
                \\var yyy = 0; // 14
                \\qqq vvv d np cc cc
            );
        }
    }

    {
        const lsuite, const buf, const dcp = try setupTestDependencies();
        defer cleanUpTestDependencies(lsuite, buf, dcp);

        // request line 3 - 5
        {
            try requestAndTestLines(.{ 3, 5 }, dcp, .{ 3, 5 },
                \\fn add(x: f32, y: f32) void { // 3
                \\kk FFFpPp tttp Pp tttp tttt p cc c
                \\    return x + y; // 4
                \\    dddddd v o vp cc c
                \\} // 5
                \\p cc c
            );
        }

        // request line 0 - 1, which is not cached, and before `DisplayCachePool.start_line`
        {
            try requestAndTestLines(.{ 0, 1 }, dcp, .{ 0, 5 },
                \\const std = @import("std"); // 0
                \\qqqqq vvv d iiiiiiipssssspp cc c
                \\const Allocator = std.mem.Allocator; // 1
                \\qqqqq ttttttttt d vvvpfffptttttttttp cc c
            );
        }
    }

    // request covers beyond cache range in both start and end
    {
        const lsuite, const buf, const dcp = try setupTestDependencies();
        defer cleanUpTestDependencies(lsuite, buf, dcp);
        _ = try dcp.requestLines(3, 5); // already tested on previous test
        try eq(.{ 3, 5 }, .{ dcp.start_line, dcp.end_line });
        {
            try requestAndTestLines(.{ 0, 9 }, dcp, .{ 0, 9 },
                \\const std = @import("std"); // 0
                \\qqqqq vvv d iiiiiiipssssspp cc c
                \\const Allocator = std.mem.Allocator; // 1
                \\qqqqq ttttttttt d vvvpfffptttttttttp cc c
                \\// 2
                \\cc c
                \\fn add(x: f32, y: f32) void { // 3
                \\kk FFFpPp tttp Pp tttp tttt p cc c
                \\    return x + y; // 4
                \\    dddddd v o vp cc c
                \\} // 5
                \\p cc c
                \\// six
                \\cc ccc
                \\fn sub(a: f32, b: f32) void { // seven
                \\kk FFFpPp tttp Pp tttp tttt p cc ccccc
                \\    return a - b; // eight
                \\    dddddd v o vp cc ccccc
                \\} // nine
                \\p cc cccc
            );
        }
    }
}

test "requestLines - no tree sitter" {
    var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
    defer buf.destroy();

    {
        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();

        // can return error
        {
            assert(buf.roperoot.weights().bols < 20);
            try shouldErr(RequestLinesError.EndLineOutOfBounds, dcp.requestLines(0, 20));
        }

        // request first 5 lines
        {
            try requestAndTestLines(.{ 0, 4 }, dcp, .{ 0, 4 },
                \\const std = @import("std"); // 0
                \\ddddd ddd d ddddddddddddddd dddd
                \\const Allocator = std.mem.Allocator; // 1
                \\ddddd ddddddddd d dddddddddddddddddd dd d
                \\// 2
                \\dd d
                \\fn add(x: f32, y: f32) void { // 3
                \\dd dddddd dddd dd dddd dddd d dd d
                \\    return x + y; // 4
                \\    dddddd d d dd dd d
            );
        }

        // request lines that are already cached (> 0 and <= 4)
        {
            try requestAndTestLines(.{ 0, 1 }, dcp, .{ 0, 4 },
                \\const std = @import("std"); // 0
                \\ddddd ddd d ddddddddddddddd dddd
                \\const Allocator = std.mem.Allocator; // 1
                \\ddddd ddddddddd d dddddddddddddddddd dd d
            );
        }

        // request lines that are not cached - after `DisplayCachePool.end_line` (> 4)
        {
            try requestAndTestLines(.{ 11, 14 }, dcp, .{ 0, 14 },
                \\pub const not_false = true; // 11
                \\ddd ddddd ddddddddd d ddddd dd dd
                \\// 12
                \\dd dd
                \\var xxx = 0; // 13
                \\ddd ddd d dd dd dd
                \\var yyy = 0; // 14
                \\ddd ddd d dd dd dd
            );
        }
    }

    // request start < DisplayCachePool.start_line
    {
        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();

        // request line 3 - 5
        {
            try requestAndTestLines(.{ 3, 5 }, dcp, .{ 3, 5 },
                \\fn add(x: f32, y: f32) void { // 3
                \\dd dddddd dddd dd dddd dddd d dd d
                \\    return x + y; // 4
                \\    dddddd d d dd dd d
                \\} // 5
                \\d dd d
            );
        }

        // request line 0 - 1, which is not cached, and before `DisplayCachePool.start_line`
        {
            try requestAndTestLines(.{ 0, 1 }, dcp, .{ 0, 5 },
                \\const std = @import("std"); // 0
                \\ddddd ddd d ddddddddddddddd dd d
                \\const Allocator = std.mem.Allocator; // 1
                \\ddddd ddddddddd d dddddddddddddddddd dd d
            );
        }
    }

    // request covers beyond cache range in both start and end
    {
        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();
        _ = try dcp.requestLines(3, 5); // already tested on previous test
        {
            try requestAndTestLines(.{ 0, 9 }, dcp, .{ 0, 9 },
                \\const std = @import("std"); // 0
                \\ddddd ddd d ddddddddddddddd dd d
                \\const Allocator = std.mem.Allocator; // 1
                \\ddddd ddddddddd d dddddddddddddddddd dd d
                \\// 2
                \\dd d
                \\fn add(x: f32, y: f32) void { // 3
                \\dd dddddd dddd dd dddd dddd d dd d
                \\    return x + y; // 4
                \\    dddddd d d dd dd d
                \\} // 5
                \\d dd d
                \\// six
                \\dd ddd
                \\fn sub(a: f32, b: f32) void { // seven
                \\dd dddddd dddd dd dddd dddd d dd ddddd
                \\    return a - b; // eight
                \\    dddddd d d dd dd ddddd
                \\} // nine
                \\d dd dddd
            );
        }
    }
}

fn createAndAppendLinesWithDefaultDisplays(self: *@This(), start: usize, end: usize) !void {
    assert(start <= end);
    assert(start <= self.getLastLineNumberOfBuffer() and end <= self.getLastLineNumberOfBuffer());
    if (self.cached_lines.items.len == 0) try self.cached_lines.ensureTotalCapacity(end - start + 1);
    for (start..end + 1) |linenr| {
        assert(linenr <= self.getLastLineNumberOfBuffer());
        const new_line = try self.createDefaultLine(linenr);
        try self.cached_lines.append(new_line);
    }
}

fn createDefaultLinesList(self: *@This(), start: usize, end: usize) !ArrayList(Line) {
    assert(start <= end);
    assert(start <= self.getLastLineNumberOfBuffer() and end <= self.getLastLineNumberOfBuffer());
    var list = try ArrayList(Line).initCapacity(self.a, end - start + 1);
    for (start..end + 1) |linenr| {
        assert(linenr <= self.getLastLineNumberOfBuffer());
        const new_line = try self.createDefaultLine(linenr);
        try list.append(new_line);
    }
    return list;
}

fn createDefaultLine(self: *@This(), linenr: usize) !Line {
    const contents = self.buf.roperoot.getLineEx(self.a, linenr) catch unreachable;
    const line = Line{
        .contents = contents,
        .displays = try self.a.alloc(Display, contents.len),
    };
    @memset(line.displays, self.default_display);
    return line;
}

fn setStartAndEndLine(self: *@This(), start: usize, end: usize) void {
    self.start_line = start;
    self.end_line = end;
}

fn updateEndLine(self: *@This(), len_diff: i128) void {
    const new_end_line = @as(i128, @intCast(self.end_line)) + len_diff;
    assert(new_end_line >= 0);
    self.end_line = @intCast(new_end_line);
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert

const InsertCharsError = error{OutOfMemory};
pub fn insertChars(self: *@This(), line: usize, col: usize, chars: []const u8) InsertCharsError!void {
    assert(line <= self.getLastLineNumberOfBuffer());
    assert(col <= self.buf.roperoot.getNumOfCharsOfLine(line) catch unreachable);

    const new_pos, const may_ts_ranges = self.buf.insertChars(chars, line, col) catch |err| switch (err) {
        error.LineOutOfBounds => @panic("encountered error.LineOutOfBounds despite `line <= getLastLineNumberOfBuffer()` assertion"),
        error.ColOutOfBounds => @panic("encountered error.ColOutOfBounds despite `col <= try getNumOfCharsOfLine(line)` assertion"),
        error.OutOfMemory => return error.OutOfMemory,
    };

    const cstart = line;
    const cend = new_pos.line;
    assert(cstart <= cend);

    const update_params = .{
        .lines = .{ .old_start = cstart, .old_end = cstart, .new_start = cstart, .new_end = cend },
    };
    try self.update(update_params);

    _ = may_ts_ranges;
}

test "insertChars - no tree sitter" {
    var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
    defer buf.destroy();

    // changes happen only in 1 line
    {
        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();

        try requestAndTestLines(.{ 0, 0 }, dcp, .{ 0, 0 },
            \\const std = @import("std"); // 0
            \\ddddd ddd d ddddddddddddddd dddd
        );

        try dcp.insertChars(0, 0, "// ");
        try eq(.{ 0, 0 }, .{ dcp.start_line, dcp.end_line });

        try requestAndTestLines(.{ 0, 0 }, dcp, .{ 0, 0 },
            \\// const std = @import("std"); // 0
            \\dd ddddd ddd d ddddddddddddddd dddd
        );
    }

    // changes spans across multiple lines
    {
        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();

        try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 5 },
            \\// const std = @import("std"); // 0
            \\dd ddddd ddd d ddddddddddddddd dddd
            \\const Allocator = std.mem.Allocator; // 1
            \\ddddd ddddddddd d dddddddddddddddddd dd d
            \\// 2
            \\dd d
            \\fn add(x: f32, y: f32) void { // 3
            \\dd dddddd dddd dd dddd dddd d dd d
            \\    return x + y; // 4
            \\    dddddd d d dd dd d
            \\} // 5
            \\d dd d
        );

        try dcp.insertChars(0, 0, "// new line 0\n");
        try eq(.{ 0, 6 }, .{ dcp.start_line, dcp.end_line });

        try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 6 },
            \\// new line 0
            \\dd ddd dddd d
            \\// const std = @import("std"); // 0
            \\dd ddddd ddd d ddddddddddddddd dddd
            \\const Allocator = std.mem.Allocator; // 1
            \\ddddd ddddddddd d dddddddddddddddddd dd d
            \\// 2
            \\dd d
            \\fn add(x: f32, y: f32) void { // 3
            \\dd dddddd dddd dd dddd dddd d dd d
            \\    return x + y; // 4
            \\    dddddd d d dd dd d
        );

        try dcp.insertChars(3, 0, "some\nmore\nlines ");
        try eq(.{ 0, 8 }, .{ dcp.start_line, dcp.end_line });

        try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 8 },
            \\// new line 0
            \\dd ddd dddd d
            \\// const std = @import("std"); // 0
            \\dd ddddd ddd d ddddddddddddddd dddd
            \\const Allocator = std.mem.Allocator; // 1
            \\ddddd ddddddddd d dddddddddddddddddd dd d
            \\some
            \\dddd
            \\more
            \\dddd
            \\lines // 2
            \\ddddd dd d
        );
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Delete

pub fn deleteRange(self: *@This(), a: Point, b: Point) !void {
    const start, const end = sortPoints(a, b);
    const may_ts_ranges = try self.buf.deleteRange(start, end);

    const update_params = .{
        .lines = .{ .old_start = start[0], .old_end = end[0], .new_start = start[0], .new_end = start[0] },
    };
    try self.update(update_params);

    _ = may_ts_ranges;
}

test "deleteRange - no tree sitter" {
    {
        var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
        defer buf.destroy();

        // changes happen only in 1 line
        {
            var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
            defer dcp.deinit();

            try requestAndTestLines(.{ 0, 0 }, dcp, .{ 0, 0 },
                \\const std = @import("std"); // 0
                \\ddddd ddd d ddddddddddddddd dddd
            );

            try dcp.deleteRange(.{ 0, 0 }, .{ 0, 6 });
            try eq(.{ 0, 0 }, .{ dcp.start_line, dcp.end_line });

            try requestAndTestLines(.{ 0, 0 }, dcp, .{ 0, 0 },
                \\std = @import("std"); // 0
                \\ddd d ddddddddddddddd dddd
            );
        }

        // changes spans across multiple lines
        {
            var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
            defer dcp.deinit();

            try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 5 },
                \\std = @import("std"); // 0
                \\ddd d ddddddddddddddd dddd
                \\const Allocator = std.mem.Allocator; // 1
                \\ddddd ddddddddd d dddddddddddddddddd dd d
                \\// 2
                \\dd d
                \\fn add(x: f32, y: f32) void { // 3
                \\dd dddddd dddd dd dddd dddd d dd d
                \\    return x + y; // 4
                \\    dddddd d d dd dd d
                \\} // 5
                \\d dd d
            );

            try dcp.deleteRange(.{ 1, try dcp.buf.roperoot.getNumOfCharsOfLine(1) }, .{ 4, 4 });
            try eq(.{ 0, 2 }, .{ dcp.start_line, dcp.end_line });

            try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 5 },
                \\std = @import("std"); // 0
                \\ddd d ddddddddddddddd dddd
                \\const Allocator = std.mem.Allocator; // 1return x + y; // 4
                \\ddddd ddddddddd d dddddddddddddddddd dd ddddddd d d dd dd d
                \\} // 5
                \\d dd d
                \\// six
                \\dd ddd
                \\fn sub(a: f32, b: f32) void { // seven
                \\dd dddddd dddd dd dddd dddd d dd ddddd
                \\    return a - b; // eight
                \\    dddddd d d dd dd ddddd
            );
        }
    }

    // check for rope-related bug
    {
        var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
        defer buf.destroy();

        var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
        defer dcp.deinit();

        try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 5 },
            \\const std = @import("std"); // 0
            \\ddddd ddd d ddddddddddddddd dddd
            \\const Allocator = std.mem.Allocator; // 1
            \\ddddd ddddddddd d dddddddddddddddddd dd d
            \\// 2
            \\dd d
            \\fn add(x: f32, y: f32) void { // 3
            \\dd dddddd dddd dd dddd dddd d dd d
            \\    return x + y; // 4
            \\    dddddd d d dd dd d
            \\} // 5
            \\d dd d
        );

        try dcp.deleteRange(.{ 1, try dcp.buf.roperoot.getNumOfCharsOfLine(1) }, .{ 4, 0 });
        try eq(.{ 0, 2 }, .{ dcp.start_line, dcp.end_line });

        try requestAndTestLines(.{ 0, 5 }, dcp, .{ 0, 5 },
            \\const std = @import("std"); // 0
            \\ddddd ddd d ddddddddddddddd dddd
            \\const Allocator = std.mem.Allocator; // 1    return x + y; // 4
            \\ddddd ddddddddd d dddddddddddddddddd dd d    dddddd d d dd dd d
            \\} // 5
            \\d dd d
            \\// six
            \\dd ddd
            \\fn sub(a: f32, b: f32) void { // seven
            \\dd dddddd dddd dd dddd dddd d dd ddddd
            \\    return a - b; // eight
            \\    dddddd d d dd dd ddddd
        );
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Update

const UpdateError = error{OutOfMemory};
fn update(self: *@This(), params: UpdateParameters) UpdateError!void {
    const old_len: i128 = @intCast(self.cached_lines.items.len);
    try self.updateObsoleteLinesWithNewContentsAndDefaultDisplays(params.lines);
    const len_diff: i128 = @as(i128, @intCast(self.cached_lines.items.len)) - old_len;

    self.updateEndLine(len_diff);
}

fn updateObsoleteLinesWithNewContentsAndDefaultDisplays(self: *@This(), p: UpdateParameters.Lines) !void {
    assert(p.new_start <= p.new_end);
    assert(p.new_start >= self.start_line);

    const new_lines_list = try self.createDefaultLinesList(p.new_start, p.new_end);
    defer new_lines_list.deinit();

    const replace_len = p.old_end - p.old_start + 1;
    for (0..replace_len) |i| {
        const index = p.new_start + i;
        const line = self.cached_lines.items[index];
        self.a.free(line.contents);
        self.a.free(line.displays);
    }

    try self.cached_lines.replaceRange(p.new_start, p.old_end - p.old_start + 1, new_lines_list.items);
}

fn applyTreeSitterToDisplays(self: *@This(), start_line: usize, end_line: usize) !void {
    if (self.buf.tstree == null) return;
    if (self.query_set == null) return;

    for (self.query_set.?.items) |sq| {
        const query = sq.query;

        const cursor = ts.Query.Cursor.create() catch continue;
        defer cursor.destroy();
        cursor.setPointRange(
            ts.Point{ .row = @intCast(start_line), .column = 0 },
            ts.Point{ .row = @intCast(end_line + 1), .column = 0 },
        );
        cursor.execute(query, self.buf.tstree.?.getRootNode());

        while (true) {
            const result = switch (sq.filter.nextMatchInLines(query, cursor, Buffer.contentCallback, self.buf, self.start_line, self.end_line)) {
                .match => |result| result,
                .stop => break,
            };

            var display = self.default_display;

            if (self.buf.langsuite.?.highlight_map) |hl_map| {
                if (hl_map.get(result.cap_name)) |color| {
                    if (self.default_display.variant == .char) display.variant.char.color = color;
                }
            }

            if (result.directives) |directives| {
                for (directives) |d| {
                    switch (d) {
                        .font => |face| {
                            if (display.variant == .char) display.variant.char.font_face = face;
                        },
                        .size => |size| {
                            if (display.variant == .char) display.variant.char.font_size = size;
                        },
                        .img => |path| {
                            if (display.variant == .image) {
                                display.variant.image.path = path;
                                break;
                            }
                        },
                        else => {},
                    }
                }
            }

            const node_start = result.cap_node.getStartPoint();
            const node_end = result.cap_node.getEndPoint();
            for (node_start.row..node_end.row + 1) |linenr| {
                if (linenr > self.end_line) continue;
                assert(linenr >= self.start_line);
                const line_index = linenr - self.start_line;
                const start_col = if (linenr == node_start.row) node_start.column else 0;
                const end_col = if (linenr == node_end.row)
                    node_end.column
                else
                    self.cached_lines.items[line_index].contents.len;

                if (start_col > end_col) continue;
                const limit = self.cached_lines.items[line_index].displays.len;
                if (start_col > limit or end_col > limit) continue;

                @memset(self.cached_lines.items[line_index].displays[start_col..end_col], display);
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Info

fn getLastLineNumberOfBuffer(self: *@This()) usize {
    return self.getNumberOfLinesFromBuffer() - 1;
}

fn getNumberOfLinesFromBuffer(self: *@This()) usize {
    return self.buf.roperoot.weights().bols;
}

fn getWidth(self: *@This()) f32 {
    _ = self;
    unreachable;
}

fn getHeight(self: *@This()) f32 {
    _ = self;
    unreachable;
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const QuerySet = ArrayList(*sitter.StoredQuery);

const Point = struct {
    usize,
    usize,
};
fn sortPoints(a: Point, b: Point) struct { Point, Point } {
    if (a[0] == b[0]) {
        if (a[1] < b[1]) return .{ a, b };
        return .{ b, a };
    }
    if (a[0] < b[0]) return .{ a, b };
    return .{ b, a };
}

const CellIndex = struct { line: usize, col: usize };

const Line = struct {
    contents: []u21,
    displays: []Display,
};

const UpdateParameters = struct {
    const Lines = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };
    lines: UpdateParameters.Lines,
};

const Display = struct {
    width: f32 = 0,
    height: f32 = 0,
    variant: union(enum) {
        const Char = struct {
            font_size: f32,
            font_face: []const u8,
            color: u32,
        };
        const Image = struct {
            path: []const u8,
        };
        char: Char,
        image: Image,
        char_conceal: Char,
        image_conceal: Image,
        being_concealed,
    },
};

const __dummy_default_display = Display{
    .variant = .{
        .char = .{
            .font_size = 40,
            .font_face = "Meslo",
            .color = 0xF5F5F5F5,
        },
    },
};

////////////////////////////////////////////////////////////////////////////////////////////// Helpers

fn setupTestDependencies() !struct { *sitter.LangSuite, *Buffer, *DisplayCachePool } {
    var lsuite = try sitter.LangSuite.create(testing_allocator, .zig);
    try lsuite.initializeQueryMap(testing_allocator);
    try lsuite.initializeNightflyColorscheme(testing_allocator);

    var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
    try buf.initiateTreeSitter(lsuite);

    var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
    try dcp.enableQueries(&.{sitter.DEFAULT_QUERY_ID});

    return .{ lsuite, buf, dcp };
}

fn cleanUpTestDependencies(lsuite: *sitter.LangSuite, buf: *Buffer, dcp: *DisplayCachePool) void {
    lsuite.destroy();
    buf.destroy();
    dcp.deinit();
}

const ExpectedDisplayMap = std.AutoHashMap(u8, Display);
fn createExpectedDisplayMap(dcp: *DisplayCachePool) !ExpectedDisplayMap {
    var map = ExpectedDisplayMap.init(testing_allocator);

    try map.put('d', dcp.default_display);
    if (dcp.buf.langsuite == null) return map;

    try map.put('q', createDisplayFromHlGroup(dcp, "type.qualifier"));
    try map.put('c', createDisplayFromHlGroup(dcp, "comment"));
    try map.put('t', createDisplayFromHlGroup(dcp, "type"));
    try map.put('v', createDisplayFromHlGroup(dcp, "variable"));
    try map.put('i', createDisplayFromHlGroup(dcp, "include"));
    try map.put('k', createDisplayFromHlGroup(dcp, "keyword"));
    try map.put('s', createDisplayFromHlGroup(dcp, "string"));
    try map.put('f', createDisplayFromHlGroup(dcp, "field"));
    try map.put('F', createDisplayFromHlGroup(dcp, "function"));
    try map.put('b', createDisplayFromHlGroup(dcp, "boolean"));
    try map.put('n', createDisplayFromHlGroup(dcp, "number"));
    try map.put('o', createDisplayFromHlGroup(dcp, "operator"));
    try map.put('p', createDisplayFromHlGroup(dcp, "punctuation.bracket"));
    try map.put('P', createDisplayFromHlGroup(dcp, "parameter"));

    return map;
}

fn createDisplayFromHlGroup(dcp: *DisplayCachePool, hl_group: []const u8) Display {
    var display = dcp.default_display;
    const color = dcp.buf.langsuite.?.highlight_map.?.get(hl_group) orelse {
        std.debug.print("hl_group: '{s}' not found\n", .{hl_group});
        unreachable;
    };
    display.variant.char.color = color;
    return display;
}

const TestRange = struct { usize, usize };
fn requestAndTestLines(request_range: TestRange, dcp: *DisplayCachePool, cache_range: TestRange, expected_str: []const u8) !void {
    var display_map = try createExpectedDisplayMap(dcp);
    defer display_map.deinit();

    const lines = try dcp.requestLines(request_range[0], request_range[1]);

    try eq(dcp.start_line, cache_range[0]);
    try eq(dcp.end_line, cache_range[1]);
    try eq(dcp.cached_lines.items.len, cache_range[1] - cache_range[0] + 1);

    var split_iter = std.mem.split(u8, expected_str, "\n");
    var tracker: usize = 0;
    var i: usize = 0;
    var expected_contents: []const u8 = undefined;
    var expected_displays: []const u8 = undefined;
    while (split_iter.next()) |test_line| {
        defer tracker += 1;
        if (tracker % 2 == 0) {
            expected_contents = test_line;
            continue;
        }

        defer i += 1;

        try eqStrU21(expected_contents, lines[i].contents);

        expected_displays = test_line;
        for (expected_displays, 0..) |key, j| {
            if (lines[i].contents[j] == ' ') continue; // skip ' ' for less clutter
            const expected = display_map.get(key) orelse @panic("can't find expected display");
            errdefer std.debug.print("failed at i: {d} | j: {d}\n", .{ i, j });
            try eqDisplay(expected, lines[i].displays[j]);
        }
    }

    try eq(i, lines.len);
}

fn testLinesContents(lines: []Line, expected_str: []const u8) !void {
    var split_iter = std.mem.split(u8, expected_str, "\n");
    var i: usize = 0;
    while (split_iter.next()) |expected| {
        defer i += 1;
        try eqStrU21(expected, lines[i].contents);
        try eq(lines[i].contents.len, lines[i].displays.len);
    }
    try eq(i, lines.len);
}

fn eqDisplay(expected: Display, got: Display) !void {
    switch (expected.variant) {
        .char => |char| {
            errdefer std.debug.print("wanted 0x{x} got 0x{x}\n", .{ char.color, got.variant.char.color });
            try eq(char.font_size, got.variant.char.font_size);
            try eqStr(char.font_face, got.variant.char.font_face);
            try eq(char.color, got.variant.char.color);
        },
        .image => |image| {
            try eq(image.path, got.variant.image.path);
        },
        else => unreachable,
    }
}

fn eqStrU21(expected: []const u8, got: []u21) !void {
    var slice = try testing_allocator.alloc(u8, got.len);
    defer testing_allocator.free(slice);
    for (got, 0..) |cp, i| slice[i] = @intCast(cp);
    try eqStr(expected, slice);
}

////////////////////////////////////////////////////////////////////////////////////////////// Patterns for Testing
