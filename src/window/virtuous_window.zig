const std = @import("std");
const __buf_mod = @import("neo_buffer");
const Buffer = __buf_mod.Buffer;
const sitter = __buf_mod.sitter;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const Dimensions = union(enum) {
    bounded: struct {
        x: f32,
        y: f32,
        width: f32 = 400,
        height: f32 = 400,
    },
    unbound: struct {
        x: f32,
        y: f32,
    },
};

/// A slice of `[]const u8` values. Each `[]const u8` represents a single character,
/// regardless of its byte length.
const Line = [][]const u8;

/// A slice of `u32` values. Each `u32` represents an RGBA color.
const LineColors = []u32;

/// Holds text content and color content for each line that Window holds.
/// Window can hold more contents than it can display.
/// Let's say Window height makes it can only display 40 lines,
/// but internally it can hold say for example 80 lines, 400 lines, etc...
/// The number of lines a Window should hold is still being worked on.
const Contents = struct {
    lines: []Line,
    line_colors: []LineColors,
};

pub const Window = struct {
    exa: Allocator,
    buf: *Buffer,
    cursor: Cursor,
    dimensions: Dimensions,
    font_size: i32 = 40,

    pub fn spawn(exa: Allocator, buf: *Buffer, font_size: i32, dimensions: Dimensions) !*@This() {
        const self = try exa.create(@This());
        self.* = .{
            .exa = exa,
            .buf = buf,
            .cursor = Cursor{},
            .dimensions = dimensions,
            .font_size = font_size,

            // we have a problem here...
            // how do we know how many lines to store and parse?
            // so we have the window height and the font size..
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        self.exa.destroy(self);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    pub fn set(self: *Cursor, line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }
};
