const Window = @This();
const std = @import("std");

const Buffer = @import("neo_buffer").Buffer;
const sitter = @import("ts");
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Window

a: Allocator,
buf: *Buffer,

cursor: Cursor = .{},

content_restrictiosn: ContentRestrictions = .none,
cached: CachedContents,

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
        entire_file,
        section: Section,
    };

    arena: ArenaAllocator,
    win: *const Window,

    lines: ArrayList([]u21),
    displays: ArrayList([]Display),

    start_line: usize = 0,
    end_line: usize = 0,

    fn init(win: *const Window, strategy: CacheStrategy) !@This() {
        var self = CachedContents{
            .arena = ArenaAllocator.init(std.heap.page_allocator),
            .win = win,
            .lines = ArrayList([]u21).init(win.a),
            .displays = ArrayList([]Display).init(win.a),
        };
        switch (strategy) {
            .entire_file => {
                self.end_line = win.buf.roperoot.weights().bols -| 1;
            },
            .section => |section| {
                self.start_line = section.start_line;
                self.end_line = section.end_line;
            },
        }
        try self.createLines();
        return self;
    }

    fn deinit(self: *@This()) void {
        self.arena.deinit();
    }

    fn createLines(self: *@This()) !void {
        // TODO:
    }
};

const ContentRestrictions = union(enum) {
    none,
    restricted: struct { start_line: usize, end_line: usize },
};

const Cursor = struct { line: usize = 0, col: usize = 0 };

////////////////////////////////////////////////////////////////////////////////////////////// Tests
