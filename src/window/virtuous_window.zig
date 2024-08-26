const std = @import("std");
const __buf_mod = @import("neo_buffer");
const Buffer = __buf_mod.Buffer;
const sitter = __buf_mod.sitter;
const ts = sitter.b;

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
            const end_line = start_line + num_of_lines;

            // add lines
            var lines = try win.exa.alloc(Line, num_of_lines);
            for (start_line..start_line + num_of_lines, 0..) |linenr, i| {
                lines[i] = try win.buf.roperoot.getLineEx(win.exa, linenr);
            }

            // add default color
            var line_colors = try win.exa.alloc(LineColors, num_of_lines);
            for (lines, 0..) |line, i| {
                line_colors[i] = try win.exa.alloc(u32, line.len);
                @memset(line_colors[i], 0xF5F5F5F5);
            }

            // add TS highlights
            if (win.buf.langsuite) |langsuite| {
                const cursor = try ts.Query.Cursor.create();
                cursor.setPointRange(
                    ts.Point{ .row = @intCast(start_line), .column = 0 },
                    ts.Point{ .row = @intCast(end_line + 1), .column = 0 },
                );
                cursor.execute(langsuite.query.?, win.buf.tstree.?.getRootNode());
                defer cursor.destroy();

                while (true) {
                    const result = langsuite.filter.?.nextMatchInLines(langsuite.query.?, cursor, Buffer.contentCallback, win.buf, start_line, end_line);
                    switch (result) {
                        .match => |match| if (match.match == null) break,
                        .ignore => break,
                    }
                    const match = result.match;
                    if (langsuite.highlight_map.?.get(match.cap_name)) |color| {
                        const node_start = match.cap_node.?.getStartPoint();
                        const node_end = match.cap_node.?.getEndPoint();
                        for (node_start.row..node_end.row + 1) |linenr| {
                            const line_index = linenr - start_line;
                            const start_col = if (linenr == node_start.row) node_start.column else 0;
                            const end_col = if (linenr == node_end.row) node_end.column else lines[line_index].len;
                            @memset(line_colors[line_index][start_col..end_col], color);
                        }
                    }
                }
            }

            return .{
                .window = win,
                .start_line = start_line,
                .end_line = end_line,
                .lines = lines,
                .line_colors = line_colors,
            };
        }

        test createWithCapacity {
            var langsuite = try sitter.LangSuite.create(.zig);
            defer langsuite.destroy();
            try langsuite.createQuery();
            try langsuite.initializeFilter(testing_allocator);
            try langsuite.initializeHighlightMap(testing_allocator);

            var buf = try Buffer.create(testing_allocator, .string, "const std");
            defer buf.destroy();
            try buf.initiateTreeSitter(langsuite);

            var win = try Window.spawn(testing_allocator, buf, 40, .{ .unbound = .{ .x = 100, .y = 100 } });
            defer win.destroy();
        }

        fn destroy(self: *@This()) void {
            for (self.lines) |line| self.window.exa.free(line);
            for (self.line_colors) |lc| self.window.exa.free(lc);
            self.window.exa.free(self.lines);
            self.window.exa.free(self.line_colors);
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
        self.contents.destroy();
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

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(Window);
}
