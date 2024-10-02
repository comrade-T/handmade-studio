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

const RequestLinesError = error{ OutOfMemory, EndLineOutOfBounds };
pub fn requestLines(self: *@This(), start: usize, end: usize) RequestLinesError![]Line {
    if (end > self.getLastLineNumberOfBuffer()) return RequestLinesError.EndLineOutOfBounds;
    assert(self.cachedLinesAreSorted());

    if (self.cached_lines.items.len == 0) {
        self.cached_lines = try self.createCachedLinesWithDefaultDisplays(start, end);
        return self.cached_lines.items;
    }

    unreachable;
}

test "requestLines - no tree sitter " {
    var buf = try Buffer.create(testing_allocator, .file, "dummy.zig");
    assert(buf.roperoot.weights().bols < 20);
    defer buf.destroy();

    var dcp = try DisplayCachePool.init(testing_allocator, buf, __dummy_default_display);
    defer dcp.deinit();

    try shouldErr(RequestLinesError.EndLineOutOfBounds, dcp.requestLines(0, 20));

    // request first 5 lines
    {
        const lines = try dcp.requestLines(0, 4);
        try testLines(lines,
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

    // TODO: request line 10 to last line

    //////////////////////// example of testing lines & their displays
    // const example =
    //     \\const std = @import("std"); // 0
    //     \\qqqqq 000 0 bbbbbbb0sssss00 cc c
    //     \\const Allocator = std.mem.Allocator; // 1
    //     \\// 2
    //     \\fn add(x: f32, y: f32) void { // 3
    //     \\    return x + y; // 4
    // ;
}

fn createCachedLinesWithDefaultDisplays(self: *@This(), start_line: usize, end_line: usize) !ArrayList(Line) {
    assert(start_line <= end_line);
    assert(start_line <= self.getLastLineNumberOfBuffer() and end_line <= self.getLastLineNumberOfBuffer());
    var lines = try ArrayList(Line).initCapacity(self.a, end_line - start_line + 1);
    for (start_line..end_line + 1) |linenr| {
        assert(linenr <= self.getLastLineNumberOfBuffer());
        const contents = self.buf.roperoot.getLineEx(self.a, linenr) catch unreachable;
        const displays = try self.a.alloc(Display, contents.len);
        @memset(displays, self.default_display);
        try lines.append(Line{ .linenr = linenr, .contents = contents, .displays = displays });
    }
    return lines;
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

fn testLines(lines: []Line, expected_str: []const u8) !void {
    var display_map = try createExpectedDisplayMap();
    defer display_map.deinit();

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
