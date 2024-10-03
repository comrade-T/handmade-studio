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
    self.cached_lines.deinit();
    self.a.destroy(self);
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
        return self.cached_lines.items;
    }

    // requested range already cached
    if (start >= self.start_line and end <= self.end_line) {
        return self.cached_lines.items[start .. end + 1];
    }

    if (start < self.start_line) {
        const new_lines_list = try self.createDefaultLinesList(start, self.start_line - 1);
        defer new_lines_list.deinit();
        try self.cached_lines.insertSlice(0, new_lines_list.items);
        self.setStartAndEndLine(start, self.end_line);
    }

    if (end > self.end_line) {
        try self.createAndAppendLinesWithDefaultDisplays(self.end_line + 1, end);
        self.setStartAndEndLine(self.start_line, end);
    }

    return self.cached_lines.items[(start - self.start_line)..(end - self.start_line + 1)];
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
        try requestAndTestLines(.{ 0, 0 }, dcp, .{ 0, 0 },
            \\// const std = @import("std"); // 0
            \\dd ddddd ddd d ddddddddddddddd dddd
        );
    }

    // changes spans across 2 lines
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

////////////////////////////////////////////////////////////////////////////////////////////// Update

const UpdateError = error{OutOfMemory};
fn update(self: *@This(), params: UpdateParameters) UpdateError!void {
    const len_diff = try self.updateObsoleteLinesWithNewContentsAndDefaultDisplays(params.lines);
    self.updateEndLine(len_diff);
}

fn updateObsoleteLinesWithNewContentsAndDefaultDisplays(self: *@This(), p: UpdateParameters.Lines) !i128 {
    assert(p.new_start <= p.new_end);
    assert(p.new_start >= self.start_line);

    const old_len: i128 = @intCast(self.cached_lines.items.len);
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

    const len_diff: i128 = @as(i128, @intCast(self.cached_lines.items.len)) - old_len;
    assert(self.end_line + len_diff >= self.start_line);
    return len_diff;
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

const ExpectedDisplayMap = std.AutoHashMap(u8, Display);
fn createExpectedDisplayMap() !ExpectedDisplayMap {
    var map = ExpectedDisplayMap.init(testing_allocator);

    try map.put('d', __dummy_default_display);

    return map;
}

const Range = struct { usize, usize };
fn requestAndTestLines(request_range: Range, dcp: *DisplayCachePool, cache_range: Range, expected_str: []const u8) !void {
    var display_map = try createExpectedDisplayMap();
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
