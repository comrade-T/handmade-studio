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

pub const Window = struct {
    exa: Allocator,
    buf: *Buffer,
    cursor: Cursor,
    dimensions: Dimensions,
    font_size: i32,
    contents: Contents = undefined,

    const Dimensions = union(enum) {
        bounded: struct {
            x: f32,
            y: f32,
            width: f32,
            height: f32,
            offset: struct { x: f32, y: f32 } = .{ .x = 0, .y = 0 },
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
        window: *Window,
        lines: []Line,
        line_colors: []LineColors,
        start_line: usize,
        end_line: usize,

        fn createWithCapacity(win: *Window, start_line: usize, num_of_lines: usize) !Contents {
            // add lines
            var lines = try win.exa.alloc(LineColors, num_of_lines);
            for (start_line..start_line + num_of_lines, 0..) |linenr, i| {
                lines[i] = try win.buf.roperoot.getLineEx(win.exa, linenr);
            }

            // add colors
            var line_colors = try win.exa.alloc(LineColors, num_of_lines);
            for (lines, 0..) |line, i| {
                line_colors[i] = try win.exa.alloc(u32, line.len);
                @memset(line_colors[i], 0xF5F5F5F5);
            }

            // TODO: add TS highlights
            // where do I even get highlights hashmap??
            // from `sitter`, of course!

            return .{
                .start_line = start_line,
                .end_line = start_line + num_of_lines,
                .lines = lines,
                .line_colors = line_colors,
            };
        }
    };

    pub fn spawn(exa: Allocator, buf: *Buffer, font_size: i32, dimensions: Dimensions) !*@This() {
        const self = try exa.create(@This());
        self.* = .{
            .exa = exa,
            .buf = buf,
            .cursor = Cursor{},
            .dimensions = dimensions,
            .font_size = font_size,
        };

        // store the content of the entire buffer for now,
        // we'll explore more delicate solutions after we deal with scissor mode.
        const start_line = 0;
        const num_of_lines = buf.roperoot.weights().bols;
        self.contents = try Contents.createWithCapacity(self, start_line, num_of_lines);

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
