const std = @import("std");
const __buf_mod = @import("neo_buffer");
const Buffer = __buf_mod.Buffer;
const sitter = __buf_mod.sitter;
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const idc_if_it_leaks = std.heap.page_allocator;
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
    contents: Contents = undefined,

    font_size: i32,
    line_spacing: i32 = 2,

    const Cursor = struct {
        line: usize = 0,
        col: usize = 0,

        pub fn set(self: *Cursor, line: usize, col: usize) void {
            self.line = line;
            self.col = col;
        }
    };

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

    ///////////////////////////// Code Point Iterator

    const CodePointIterator = struct {
        win: *const Window,
        font_data: FontData,
        index_map: FontDataIndexMap,
        screen: Screen,

        current_line: usize = 0,
        current_col: usize = 0,
        current_x: f32 = 0,
        current_y: f32 = 0,

        pub fn create(win: *const Window, font_data: FontData, index_map: FontDataIndexMap, screen: Screen) CodePointIterator {
            var self = CodePointIterator{
                .win = win,
                .screen = screen,
                .font_data = font_data,
                .index_map = index_map,
            };

            switch (win.dimensions) {
                .bounded => |d| {
                    const cut_above: usize = @intFromFloat(@divTrunc(d.offset.y, @as(f32, @floatFromInt(win.font_size))));
                    self.current_line = cut_above;
                },
                .unbound => {},
            }

            return self;
        }

        pub fn next(self: *@This()) ?CodePoint {
            defer self.current_col += 1;

            // advance to next line if reached eol
            if (self.current_col >= self.win.contents.lines[self.current_line].len) {
                self.current_line += 1;
                self.current_col = 0;
                self.current_x = 0;
                self.current_y += @floatFromInt(self.win.font_size + self.win.line_spacing);
            }

            // return null if there's no next line
            if (self.current_line >= self.win.contents.lines.len) return null;

            // get code point
            const char = self.win.contents.lines[self.current_line][self.current_col];
            var cp_iter = __buf_mod.code_point.Iterator{ .bytes = char };
            const cp_i32: i32 = @intCast(cp_iter.next().?.code);

            // char width
            const glyph_index = self.index_map.get(cp_i32) orelse @panic("CodePoint doesn't exist in Font!");
            var char_width: f32 = @floatFromInt(self.font_data.glyphs[glyph_index].advanceX);
            if (char_width == 0) char_width = self.font_data.recs[glyph_index].width + @as(f32, @floatFromInt(self.font_data.glyphs[glyph_index].offsetX));
            defer self.current_x += char_width;

            return CodePoint{
                .value = cp_i32,
                .color = self.win.contents.line_colors[self.current_line][self.current_col],
                .x = self.current_x,
                .y = self.current_y,
                .font_size = self.win.font_size,
            };
        }
    };

    pub fn codePointIter(self: *@This(), font_data: FontData, index_map: FontDataIndexMap, screen: Screen) CodePointIterator {
        return CodePointIterator.create(self, font_data, index_map, screen);
    }
};

test Window {
    const a = idc_if_it_leaks;
    const langsuite = try setupLangSuite(a, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();
    {
        var win = try setupBufAndWin(a, langsuite, "const a = true;\nvar ten = 10;", 40, .{ .unbound = .{ .x = 0, .y = 0 } });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 0, .end_y = 0 });
        try testIterBatch(&iter, "const", "type.qualifier", 0, 0, 15);
        try testIterBatch(&iter, " a = ", "variable", 75, 0, 15);
        try testIterBatch(&iter, "true", "boolean", 150, 0, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 210, 0, 15);
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15);
        try testIterBatch(&iter, " ten = ", "variable", 45, 42, 15);
        try testIterBatch(&iter, "10", "number", 150, 42, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 180, 42, 15);
        try eq(null, iter.next());
    }
}

fn testIterBatch(iter: *Window.CodePointIterator, sequence: []const u8, hl_group: []const u8, start_x: f32, y: f32, x_inc: f32) !void {
    var cp_iter = __buf_mod.code_point.Iterator{ .bytes = sequence };
    while (cp_iter.next()) |cp| {
        const result = iter.next().?;
        try eq(cp.code, result.value);
        try eq(iter.win.buf.langsuite.?.highlight_map.?.get(hl_group).?, result.color);
        try eq(start_x + (x_inc * @as(f32, @floatFromInt(cp_iter.i - 1))), result.x);
        try eq(y, result.y);
    }
}

fn setupLangSuite(a: Allocator, lang_choice: sitter.SupportedLanguages) !sitter.LangSuite {
    var langsuite = try sitter.LangSuite.create(lang_choice);
    try langsuite.initializeQuery();
    try langsuite.initializeFilter(a);
    try langsuite.initializeHighlightMap(a);
    return langsuite;
}

fn setupBufAndWin(a: Allocator, langsuite: sitter.LangSuite, source: []const u8, font_size: i32, dimensions: Window.Dimensions) !*Window {
    var buf = try Buffer.create(a, .string, source);
    try buf.initiateTreeSitter(langsuite);
    return try Window.spawn(a, buf, font_size, dimensions);
}
fn teardownWindow(win: *Window) void {
    win.buf.destroy();
    win.destroy();
}

fn setupFontDataAndIndexMap() !struct { FontData, FontDataIndexMap } {
    const a = idc_if_it_leaks;
    var file = try std.fs.cwd().openFile("src/window/font_data.json", .{});
    const json_str = try file.readToEndAlloc(a, 1024 * 1024 * 10);
    const font_data = try std.json.parseFromSlice(FontData, a, json_str, .{});
    const index_map = try createFontDataIndexMap(a, font_data.value);
    return .{ font_data.value, index_map };
}

pub const FontDataIndexMap = std.AutoHashMap(i32, usize);
fn createFontDataIndexMap(a: Allocator, font_data: FontData) !FontDataIndexMap {
    var map = FontDataIndexMap.init(a);
    for (0..font_data.glyphs.len) |i| try map.put(font_data.glyphs[i].value, i);
    return map;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CodePoint = struct {
    value: i32,
    color: u32,
    x: f32,
    y: f32,
    font_size: i32,
};

const Screen = struct {
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
};

//////////////////////////////////////////////////////////////////////////////////////////////

// These structs exist so that this module doeesn't have to import Raylib.
// These structs are trimmed down versions of Raylib equivalents.

pub const GlyphData = struct {
    advanceX: i32,
    offsetX: i32,
    value: i32,
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const FontData = struct {
    base_size: i32,
    glyph_padding: i32,
    recs: []Rectangle,
    glyphs: []GlyphData,
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(Window);
    std.testing.refAllDeclsRecursive(Window.CodePointIterator);
}
