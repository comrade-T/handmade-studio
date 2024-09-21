const Window = @This();
const std = @import("std");

const Buffer = @import("neo_buffer").Buffer;
const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const idc_if_it_leaks = std.heap.page_allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Window

a: Allocator,
buf: *Buffer,

cursor: Cursor = .{},

content_restrictiosn: ContentRestrictions = .none,
cached: CachedContents = undefined,

pub fn create(a: Allocator, buf: *Buffer) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .buf = buf,
    };
    return self;
}

test create {
    var buf = try Buffer.create(testing_allocator, .string, "");
    defer buf.destroy();
    var win = try Window.create(testing_allocator, buf);
    defer win.destroy();
    try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
}

pub fn destroy(self: *@This()) void {
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Supporting Structs

const CachedContents = struct {
    const Display = union(enum) {
        const Char = struct { font_size: i32, font_face: []const u8, color: u32 };
        const Image = struct { path: []const u8 };
        char: Char,
        image: Image,
    };
    const CacheStrategy = union(enum) {
        const Section = struct { start_line: usize, end_line: usize };
        entire_buffer,
        section: Section,
    };

    arena: ArenaAllocator,
    win: *const Window,

    lines: AutoArrayHashMap(usize, []u21) = undefined,
    displays: ArrayList([]Display) = undefined,

    start_line: usize = 0,
    end_line: usize = 0,

    fn init(win: *const Window, strategy: CacheStrategy) !@This() {
        var self = try CachedContents.init_bare_internal(win, strategy);
        self.lines = try createLines(self.arena.allocator(), win, self.start_line, self.end_line);
        return self;
    }

    fn init_bare_internal(win: *const Window, strategy: CacheStrategy) !@This() {
        var self = CachedContents{
            .arena = ArenaAllocator.init(std.heap.page_allocator),
            .win = win,
        };
        switch (strategy) {
            .entire_buffer => {
                self.end_line = win.buf.roperoot.weights().bols -| 1;
            },
            .section => |section| {
                self.start_line = section.start_line;
                self.end_line = section.end_line;
            },
        }
        return self;
    }

    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    const CreateLinesError = error{ OutOfMemory, LineOutOfBounds };
    fn createLines(a: Allocator, win: *const Window, start_line: usize, end_line: usize) CreateLinesError!AutoArrayHashMap(usize, []u21) {
        var lines = AutoArrayHashMap(usize, []u21).init(a);
        for (start_line..end_line + 1) |linenr| {
            const line = try win.buf.roperoot.getLineEx(a, linenr);
            try lines.put(linenr, line);
        }
        return lines;
    }

    test createLines {
        const buf = try Buffer.create(idc_if_it_leaks, .string, "1\n22\n333");
        const win = try Window.create(idc_if_it_leaks, buf);
        {
            var cc = try CachedContents.init_bare_internal(win, .entire_buffer);
            const lines = try createLines(cc.arena.allocator(), win, cc.start_line, cc.end_line);
            try eq(3, lines.values().len);
            try eqStrU21("1", lines.get(0).?);
            try eqStrU21("22", lines.get(1).?);
            try eqStrU21("333", lines.get(2).?);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 0);
            try eq(1, lines.values().len);
            try eqStrU21("1", lines.get(0).?);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 1);
            try eq(2, lines.values().len);
            try eqStrU21("1", lines.get(0).?);
            try eqStrU21("22", lines.get(1).?);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 1, 2);
            try eq(2, lines.values().len);
            try eqStrU21("22", lines.get(1).?);
            try eqStrU21("333", lines.get(2).?);
        }
    }
};

const ContentRestrictions = union(enum) {
    none,
    restricted: struct { start_line: usize, end_line: usize },
};

const Cursor = struct { line: usize = 0, col: usize = 0 };

////////////////////////////////////////////////////////////////////////////////////////////// Helpers

fn eqStrU21(expected: []const u8, got: []u21) !void {
    var slice = try testing_allocator.alloc(u8, got.len);
    defer testing_allocator.free(slice);
    for (got, 0..) |cp, i| slice[i] = @intCast(cp);
    try eqStr(expected, slice);
}
