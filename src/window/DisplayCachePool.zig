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

//////////////////////////////////////////////////////////////////////////////////////////////

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

///////////////////////////// requestLines

fn sortCachedLines(self: *@This()) void {
    std.mem.sort(Line, self.cached_lines.items, {}, Line.cmpByLinenr);
}

fn cachedLinesAreSorted(self: *@This()) bool {
    return std.sort.isSorted(Line, self.cached_lines.items, {}, Line.cmpByLinenr);
}

fn setStartAndEndLine(self: *@This(), start: usize, end: usize) void {
    self.start_line = start;
    self.end_line = end;
}

const RequestLinesError = error{ OutOfMemory, EndLineOutOfBounds };
pub fn requestLines(self: *@This(), start: usize, end: usize) RequestLinesError![]Line {
    if (end > self.getLastLineNumberOfBuffer()) return RequestLinesError.EndLineOutOfBounds;

    assert(start <= end);
    assert(self.cachedLinesAreSorted());

    // cache empty
    if (self.cached_lines.items.len == 0) {
        try self.createAndAppendLinesWithDefaultDisplays(start, end);
        self.setStartAndEndLine(start, end);
        return self.cached_lines.items;
    }

    // requested range already cached
    if (start <= self.start_line and end <= self.end_line) {
        return self.cached_lines.items[start .. end + 1];
    }

    if (start < self.start_line) {
        // TODO:
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

    // TODO: create tests that exposes `start < self.start_line`
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
        // {
        //     const lines = try dcp.requestLines(3, 5);
        //     try testLines(lines,
        //         \\const std = @import("std"); // 0
        //         \\ddddd ddd d ddddddddddddddd dd d
        //         \\const Allocator = std.mem.Allocator; // 1
        //         \\ddddd ddddddddd d dddddddddddddddddd dd d
        //     );
        //     try eq(0, dcp.start_line);
        //     try eq(1, dcp.end_line);
        // }
    }
}

fn createAndAppendLinesWithDefaultDisplays(self: *@This(), start: usize, end: usize) !void {
    assert(start <= end);
    assert(start <= self.getLastLineNumberOfBuffer() and end <= self.getLastLineNumberOfBuffer());
    if (self.cached_lines.items.len == 0) try self.cached_lines.ensureTotalCapacity(end - start + 1);
    for (start..end + 1) |linenr| {
        assert(linenr <= self.getLastLineNumberOfBuffer());
        const contents = self.buf.roperoot.getLineEx(self.a, linenr) catch unreachable;
        const displays = try self.a.alloc(Display, contents.len);
        @memset(displays, self.default_display);
        try self.cached_lines.append(Line{ .linenr = linenr, .contents = contents, .displays = displays });
    }
}

///////////////////////////// infos

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

//////////////////////////////////////////////////////////////////////////////////////////////

const CellIndex = struct { line: usize, col: usize };

const Line = struct {
    linenr: usize,
    contents: []u21,
    displays: []Display,
    fn cmpByLinenr(ctx: void, a: Line, b: Line) bool {
        return std.sort.asc(usize)(ctx, a.linenr, b.linenr);
    }
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
        expected_displays = test_line;

        try eqStrU21(expected_contents, lines[i].contents);
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

////////////////////////////////////////////////////////////////////////////////////////////// Experiments

test "ArrayList swap remove" {
    var list = ArrayList(u8).init(testing_allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    try eq(true, eql(u8, &.{ 1, 2, 3 }, list.items));

    const removed_element = list.swapRemove(0);
    _ = removed_element;
    try eq(true, eql(u8, &.{ 3, 2 }, list.items));

    try list.append(4);
    try eq(true, eql(u8, &.{ 3, 2, 4 }, list.items));

    list.items[0] = 100;
    try eq(true, eql(u8, &.{ 100, 2, 4 }, list.items));

    const slice = try list.toOwnedSlice();
    defer testing_allocator.free(slice);
    std.mem.sort(u8, slice, {}, comptime std.sort.asc(u8));
    try eq(true, eql(u8, &.{ 2, 4, 100 }, slice));
}

const CustomType = struct {
    index: usize,
    ptr: *[]const u8,
    fn cmpByIndex(ctx: void, a: CustomType, b: CustomType) bool {
        return std.sort.asc(usize)(ctx, a.index, b.index);
    }
};

test "custom type sort" {
    var str_list = ArrayList([]const u8).init(testing_allocator);
    defer str_list.deinit();
    try str_list.append("one");
    try str_list.append("two");
    try str_list.append("three");

    var ct_list = ArrayList(CustomType).init(testing_allocator);
    defer ct_list.deinit();

    try ct_list.append(CustomType{ .index = 2, .ptr = &str_list.items[2] });
    try ct_list.append(CustomType{ .index = 0, .ptr = &str_list.items[0] });
    try ct_list.append(CustomType{ .index = 1, .ptr = &str_list.items[1] });

    try eqStr("three", ct_list.items[0].ptr.*);
    try eqStr("one", ct_list.items[1].ptr.*);
    try eqStr("two", ct_list.items[2].ptr.*);

    std.mem.sort(CustomType, ct_list.items, {}, CustomType.cmpByIndex);

    try eqStr("one", ct_list.items[0].ptr.*);
    try eqStr("two", ct_list.items[1].ptr.*);
    try eqStr("three", ct_list.items[2].ptr.*);
}
