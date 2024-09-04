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
    contents: Contents = undefined,

    x: f32,
    y: f32,
    bounds: Bounds,
    bounded: bool,

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

    const Bounds = struct {
        width: f32 = 400,
        height: f32 = 400,
        offset: struct { x: f32, y: f32 } = .{ .x = 0, .y = 0 },
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

    pub fn spawn(exa: Allocator, buf: *Buffer, font_size: i32, x: f32, y: f32, bounds: ?Bounds) !*@This() {
        const self = try exa.create(@This());
        self.* = .{
            .exa = exa,
            .buf = buf,
            .cursor = Cursor{},
            .x = x,
            .y = y,
            .bounded = if (bounds != null) true else false,
            .bounds = if (bounds) |b| b else Bounds{},
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

    ///////////////////////////// Window Position & Bounds

    pub fn toggleBounds(self: *@This()) void {
        self.bounded = !self.bounded;
    }

    pub fn moveCursorLeft(self: *@This()) void {
        self.cursor.col -|= 1;
    }

    pub fn moveCursorRight(self: *@This()) void {
        if (self.cursor.line < self.contents.start_line or self.cursor.line > self.contents.end_line) {
            @panic("cursor line outside content range");
        }
        const current_line_index = self.cursor.line - self.contents.start_line;
        const current_line = self.contents.lines[current_line_index];
        const target_col = self.cursor.col + 1;
        if (target_col < current_line.len) self.cursor.col = target_col;
    }

    pub fn moveCursorUp(self: *@This()) void {
        self.cursor.line -|= 1;
    }

    pub fn moveCursorDown(self: *@This()) void {
        if (self.cursor.line < self.contents.start_line or self.cursor.line > self.contents.end_line) {
            @panic("cursor line outside content range");
        }
        const target_line = self.cursor.line + 1;
        if (target_line <= self.contents.end_line) {
            self.cursor.line = target_line;
            return;
        }
        @panic("vertical scrolling not implemented");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Code Point Iterator

    const CodePointIterator = struct {
        const Screen = struct {
            start_x: f32,
            start_y: f32,
            end_x: f32,
            end_y: f32,
        };

        const IterResult = union(enum) {
            code_point: CodePoint,
            skip_to_new_line,
            skip_this_char,
        };

        const CodePoint = struct {
            value: i32,
            color: u32,
            x: f32,
            y: f32,
            font_size: i32,
        };

        win: *const Window,
        font_data: FontData,
        index_map: FontDataIndexMap,
        screen: Screen,

        current_line: usize = 0,
        current_col: usize = 0,
        current_x: f32 = undefined,
        current_y: f32 = undefined,

        pub fn create(win: *const Window, font_data: FontData, index_map: FontDataIndexMap, screen: Screen) CodePointIterator {
            var self = CodePointIterator{
                .win = win,
                .screen = screen,
                .font_data = font_data,
                .index_map = index_map,
                .current_x = win.x,
                .current_y = win.y,
            };
            if (self.win.bounded) {
                self.current_x -= self.win.bounds.offset.x;
                self.current_y -= self.win.bounds.offset.y;
            }
            return self;
        }

        pub fn next(self: *@This()) ?IterResult {
            if (self.currentLineOutOfBounds()) return null;

            // screen.start_y check
            if (self.current_y + self.lineHeight() <= self.screen.start_y) return self.advanceToNextLine();

            { // screen end check
                if (self.current_x >= self.screen.end_x) return self.advanceToNextLine();
                if (self.current_y >= self.screen.end_y) return null;
            }

            // bounded check
            if (self.win.bounded) {
                // over boundary check
                if (self.current_x >= self.win.bounds.width + self.win.x) return self.advanceToNextLine();
                if (self.current_y >= self.win.bounds.height + self.win.y) return null;

                // offset check
                if (self.current_y + self.lineHeight() < self.win.y) return self.advanceToNextLine();
            }

            // col check
            if (self.currentColOutOfBounds()) return self.advanceToNextLine();

            // get code point
            const char = self.win.contents.lines[self.current_line][self.current_col];
            var cp_iter = __buf_mod.code_point.Iterator{ .bytes = char };
            const cp_i32: i32 = @intCast(cp_iter.next().?.code);

            // char width
            const glyph_index = self.index_map.get(cp_i32) orelse @panic("CodePoint doesn't exist in Font!");
            var char_width: f32 = @floatFromInt(self.font_data.glyphs[glyph_index].advanceX);
            if (char_width == 0) char_width = self.font_data.recs[glyph_index].width + @as(f32, @floatFromInt(self.font_data.glyphs[glyph_index].offsetX));

            defer self.current_x += char_width;
            defer self.current_col += 1;

            // screen.start_x check
            if (self.current_x + char_width <= self.screen.start_x) return .skip_this_char;

            return .{ .code_point = CodePoint{
                .value = cp_i32,
                .color = self.win.contents.line_colors[self.current_line][self.current_col],
                .x = self.current_x,
                .y = self.current_y,
                .font_size = self.win.font_size,
            } };
        }

        fn currentColOutOfBounds(self: *@This()) bool {
            return self.current_col >= self.win.contents.lines[self.current_line].len;
        }

        fn currentLineOutOfBounds(self: *@This()) bool {
            return self.current_line >= self.win.contents.lines.len;
        }

        fn advanceToNextLine(self: *@This()) IterResult {
            self.current_line += 1;
            self.current_col = 0;
            self.current_x = self.win.x;
            if (self.win.bounded) self.current_x -= self.win.bounds.offset.x;
            self.current_y += self.lineHeight();
            return .skip_to_new_line;
        }

        fn lineHeight(self: *@This()) f32 {
            return @floatFromInt(self.win.font_size + self.win.line_spacing);
        }
    };

    pub fn codePointIter(self: *@This(), font_data: FontData, index_map: FontDataIndexMap, screen: CodePointIterator.Screen) CodePointIterator {
        return CodePointIterator.create(self, font_data, index_map, screen);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// CodePointIterator - Window Display

test "unbound window fully on screen" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();

    // basic case, everything is visible on screen, window position .{ .x = 0, .y = 0 }.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;", 40, 0, 0, null);
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[const a = true;]
            \\[var ten = 10;]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 0, 0, 15);
        try testIterBatch(&iter, " a = ", "variable", 75, 0, 15);
        try testIterBatch(&iter, "true", "boolean", 150, 0, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 210, 0, 15);
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15);
        try testIterBatch(&iter, " ten = ", "variable", 45, 42, 15);
        try testIterBatch(&iter, "10", "number", 150, 42, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 180, 42, 15);
        try testIterNull(&iter);
    }

    // Iteration result must take window position into account.
    // In this case, window starts at position .{ .x = 100, .y = 100 }.
    // Therefore all characters position have x +100 and y +100.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;", 40, 100, 100, null);
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 100:100
            \\[const a = true;]
            \\[var ten = 10;]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 100, 100, 15);
        try testIterBatch(&iter, " a = ", "variable", 175, 100, 15);
        try testIterBatch(&iter, "true", "boolean", 250, 100, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 310, 100, 15);
        try testIterBatch(&iter, "var", "type.qualifier", 100, 142, 15);
        try testIterBatch(&iter, " ten = ", "variable", 145, 142, 15);
        try testIterBatch(&iter, "10", "number", 250, 142, 15);
        try testIterBatch(&iter, ";", "punctuation.delimiter", 280, 142, 15);
        try testIterNull(&iter);
    }
}

test "unbound window partially on screen" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();

    ///////////////////////////// don't render off screen

    { // don't render chars after screen x ends
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;", 40, 0, 0, null);
        const screen = .{ .start_x = 0, .start_y = 0, .end_x = 100, .end_y = 100 }; // anything with x > 100 shouldn't be rendered
        var iter = win.codePointIter(font_data, index_map, screen);
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[const a]
            \\[var ten]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 0, 0, 15); // x are [0, 15, 30, 45, 60], ends at 75
        try testIterBatch(&iter, " a", "variable", 75, 0, 15); // x are [75, 90], ends at 105
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ten", "variable", 45, 42, 15); // L1, x are [45, 60, 75, 90], ends at 105
        try testIterNull(&iter);
    }

    { // don't render chars before screen x starts and after screen x ends
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;", 40, 0, 0, null);
        const screen = .{ .start_x = 50, .start_y = 0, .end_x = 100, .end_y = 100 }; // anything with x + char width < 50 or x > 100 shouldn't be rendered.
        var iter = win.codePointIter(font_data, index_map, screen);
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 45:0
            \\[st a]
            \\[ ten]
        );
        try testIterBatch(&iter, "st", "type.qualifier", 45, 0, 15); // x are [45, 60], ends at 75
        try testIterBatch(&iter, " a", "variable", 75, 0, 15); // x are [75, 90], ends at 105
        try testIterBatch(&iter, " ten", "variable", 45, 42, 15); // L1, x are [45, 60, 75, 90], ends at 105
        try testIterNull(&iter);
    }

    { // don't render chars before screen y starts
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, null);
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 50, .end_x = 100, .end_y = 100 });
        try testVisibility(&iter,
            \\ 0:42
            \\[var ten]
            \\[const n]
        );
    }

    { // don't render chars after screen y ends
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, null);
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 100, .end_y = 50 });
        try testVisibility(&iter,
            \\ 0:0
            \\[const a]
            \\[var ten]
        );
    }
}

test "bounded window fully on screen, horizontal cut off" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();

    // all lines vertically visible, but lines being cut off horizontally
    // window position .{ .x = 0, .y = 0 }.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, .{
            .width = 100,
            .height = 100,
            .offset = .{ .x = 0, .y = 0 },
        });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[const a]
            \\[var ten]
            \\[const n]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 0, 0, 15); // x are [0, 15, 30, 45, 60], ends at 75
        try testIterBatch(&iter, " a", "variable", 75, 0, 15); // x are [75, 90], ends at 105
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ten", "variable", 45, 42, 15); // L1, x are [45, 60, 75, 90], ends at 105
        try testIterBatch(&iter, "const", "type.qualifier", 0, 84, 15); // L2, x are [0, 15, 30, 45, 60], ends at 75
        try testIterBatch(&iter, " n", "variable", 75, 84, 15); // L2, x are [75, 90], ends at 105
        try testIterNull(&iter);
    }

    // all lines vertically visible, but lines being cut off horizontally
    // window position .{ .x = 100, .y = 100 }.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 100, 100, .{
            .width = 100,
            .height = 100,
            .offset = .{ .x = 0, .y = 0 },
        });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 100:100
            \\[const a]
            \\[var ten]
            \\[const n]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 100, 100, 15); // x are [100, 115, 130, 145, 160], ends at 175
        try testIterBatch(&iter, " a", "variable", 175, 100, 15); // x are [175, 190], ends at 205
        try testIterBatch(&iter, "var", "type.qualifier", 100, 142, 15); // L1, x are [100, 115, 130], ends at 145
        try testIterBatch(&iter, " ten", "variable", 145, 142, 15); // L1, x are [145, 160, 175, 190], ends at 205
        try testIterBatch(&iter, "const", "type.qualifier", 100, 184, 15); // L2, x are [100, 115, 130, 145, 160], ends at 175
        try testIterBatch(&iter, " n", "variable", 175, 184, 15); // L2, x are [175, 190], ends at 205
        try testIterNull(&iter);
    }
}

test "bounded window fully on screen, vertically cut off" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();

    // window height can't contain all the lines vertically, lines are horizontally cut of,
    // window position .{ .x = 0, .y = 0 }.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, .{
            .width = 100,
            .height = 50,
            .offset = .{ .x = 0, .y = 0 },
        });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[const a]
            \\[var ten]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 0, 0, 15); // x are [0, 15, 30, 45, 60], ends at 75
        try testIterBatch(&iter, " a", "variable", 75, 0, 15); // x are [75, 90], ends at 105
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ten", "variable", 45, 42, 15); // L1, x are [45, 60, 75, 90], ends at 105
        try testIterNull(&iter);
    }

    // window height can't contain all the lines vertically, lines are horizontally cut of,
    // window position .{ .x = 100, .y = 100 }.
    {
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 100, 100, .{
            .width = 100,
            .height = 50,
            .offset = .{ .x = 0, .y = 0 },
        });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 100:100
            \\[const a]
            \\[var ten]
        );
        try testIterBatch(&iter, "const", "type.qualifier", 100, 100, 15); // x are [100, 115, 130, 145, 160], ends at 175
        try testIterBatch(&iter, " a", "variable", 175, 100, 15); // x are [175, 190], ends at 205
        try testIterBatch(&iter, "var", "type.qualifier", 100, 142, 15); // L1, x are [100, 115, 130], ends at 145
        try testIterBatch(&iter, " ten", "variable", 145, 142, 15); // L1, x are [145, 160, 175, 190], ends at 205
        try testIterNull(&iter);
    }
}

test "bounded window fully on screen, offset y cut off" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();
    const source = "const a = true;\nvar ten = 10;\nconst not_true = false;";
    {
        const offset = .{ .x = 0, .y = 50 };
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, source, 40, 0, 0, .{ .width = 500, .height = 500, .offset = offset });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:-8
            \\[var ten = 10;]
            \\[const not_true = false;]
        );
        try testIterBatch(&iter, "var", "type.qualifier", 0, -8, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ten = ", "variable", 45, -8, 15); // L1, x are [45, 60, 75, 90, 105, 120, 135], ends at 150
        try testIterBatch(&iter, "10", "number", 150, -8, 15); // L1, x are [150, 165], ends at 180
        try testIterBatch(&iter, ";", "punctuation.delimiter", 180, -8, 15); // L1, x are [180], ends at 195
        try testIterBatch(&iter, "const", "type.qualifier", 0, 34, 15); // L2, x are [0, 15, 45, 60], ends at 75
        try testIterBatch(&iter, " not_true = ", "variable", 75, 34, 15); // L2, ends at 255
        try testIterBatch(&iter, "false", "boolean", 255, 34, 15); // L2, ends at 330
        try testIterBatch(&iter, ";", "punctuation.delimiter", 330, 34, 15); // L2
        try testIterNull(&iter);
    }
    {
        const offset = .{ .x = 0, .y = 100 };
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, source, 40, 0, 0, .{ .width = 500, .height = 500, .offset = offset });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        // why -16? --> 100 - ( (40_font_size + 2_line_spacing) * 2 ) = 16
        try testVisibility(&iter,
            \\ 0:-16
            \\[const not_true = false;]
        );
    }
}

test "bounded window fully on screen, offset x cut off" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();
    const source = "const a = true;\nvar ten = 10;\nconst not_true = false;";
    {
        const offset = .{ .x = 50, .y = 0 };
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, source, 40, 0, 0, .{ .width = 500, .height = 500, .offset = offset });
        var iter = win.codePointIter(font_data, index_map, .{ .start_x = 0, .start_y = 0, .end_x = 1920, .end_y = 1080 });
        var iter_clone = iter;
        // why -5? -> 50 - 15*3 = 5
        try testVisibility(&iter_clone,
            \\ -5:0
            \\[st a = true;]
            \\[ ten = 10;]
            \\[st not_true = false;]
        );
        try testIterBatch(&iter, "st", "type.qualifier", -5, 0, 15); // L0, [-5, 10], ends at 25
        try testIterBatch(&iter, " a = ", "variable", 25, 0, 15); // L0, [25, 40, 55, 70, 85], ends at 100
        try testIterBatch(&iter, "true", "boolean", 100, 0, 15); // L0, [100, 115, 130, 145], ends at 160
        try testIterBatch(&iter, ";", "punctuation.delimiter", 160, 0, 15); // L0
        try testIterBatch(&iter, " ten = ", "variable", -5, 42, 15); // L1, [-5, 10, 25, 40, 55, 70, 85], ends at 100
        try testIterBatch(&iter, "10", "number", 100, 42, 15); // L1, [100, 115], ends at 130
        try testIterBatch(&iter, ";", "punctuation.delimiter", 130, 42, 15); // L1
        try testIterBatch(&iter, "st", "type.qualifier", -5, 84, 15); // L2, [-5, 10], ends at 25
        try testIterBatch(&iter, " not_true = ", "variable", 25, 84, 15); // L2, [25, 40, 55, 70, 85, 100, 115, 130, 145, 160, 175, 190], ends at 205
        try testIterBatch(&iter, "false", "boolean", 205, 84, 15); // L2, [205, 220, 235, 250, 265], ends at 280
        try testIterBatch(&iter, ";", "punctuation.delimiter", 280, 84, 15); // L2
    }
}

test "bounded window partially on screen" {
    const langsuite = try setupLangSuite(idc_if_it_leaks, .zig);
    const font_data, const index_map = try setupFontDataAndIndexMap();

    ///////////////////////////// only parts of window is visible on screen

    { // don't render chars after screen x ends
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, .{
            .width = 100,
            .height = 100,
            .offset = .{ .x = 0, .y = 0 },
        });
        const screen = .{ .start_x = 0, .start_y = 0, .end_x = 50, .end_y = 100 }; // anything with x > 50 shouldn't be rendered
        var iter = win.codePointIter(font_data, index_map, screen);
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[cons]
            \\[var ]
            \\[cons]
        );
        try testIterBatch(&iter, "cons", "type.qualifier", 0, 0, 15); // x are [0, 15, 30, 45], ends at 60
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ", "variable", 45, 42, 15); // L1, x are [45], ends at 60
        try testIterBatch(&iter, "cons", "type.qualifier", 0, 84, 15); // L2, x are [0, 15, 30, 45], ends at 60
        try testIterNull(&iter);
    }

    { // don't render chars after screen y ends
        var win = try setupBufAndWin(idc_if_it_leaks, langsuite, "const a = true;\nvar ten = 10;\nconst not_true = false;", 40, 0, 0, .{
            .width = 100,
            .height = 100,
            .offset = .{ .x = 0, .y = 0 },
        });
        const screen = .{ .start_x = 0, .start_y = 0, .end_x = 50, .end_y = 50 }; // anything with y + line height > 50 shouldn't be rendered
        var iter = win.codePointIter(font_data, index_map, screen);
        var iter_clone = iter;
        try testVisibility(&iter_clone,
            \\ 0:0
            \\[cons]
            \\[var ]
        );
        try testIterBatch(&iter, "cons", "type.qualifier", 0, 0, 15); // x are [0, 15, 30, 45], ends at 60
        try testIterBatch(&iter, "var", "type.qualifier", 0, 42, 15); // L1, x are [0, 15, 30], ends at 45
        try testIterBatch(&iter, " ", "variable", 45, 42, 15); // L1, x are [45], ends at 60
        try testIterNull(&iter);
    }
}

///////////////////////////// Test Helpers

fn testVisibility(iter: *Window.CodePointIterator, expected_str: []const u8) !void {
    var str = ArrayList(u8).init(testing_allocator);
    defer str.deinit();

    var started = false;

    while (iter.next()) |result| {
        switch (result) {
            .code_point => |r| {
                if (started == false) {
                    const pos_str = try std.fmt.allocPrint(testing_allocator, " {d}:{d}\n", .{ r.x, r.y });
                    defer testing_allocator.free(pos_str);
                    try str.appendSlice(pos_str);
                    try str.append('[');
                    started = true;
                }
                try str.append(@intCast(r.value));
            },
            .skip_to_new_line => if (started) try str.appendSlice("]\n["),
            .skip_this_char => continue,
        }
    }
    try eqStr(expected_str, str.items[0 .. str.items.len - 2]);
}

fn testIterNull(iter: *Window.CodePointIterator) !void {
    while (iter.next()) |result| try eq(false, result == .code_point);
}

fn testIterBatch(iter: *Window.CodePointIterator, sequence: []const u8, hl_group: []const u8, start_x: f32, y: f32, x_inc: f32) !void {
    var cp_iter = __buf_mod.code_point.Iterator{ .bytes = sequence };
    var got_result = false;
    while (iter.next()) |result| {
        switch (result) {
            .code_point => |r| {
                got_result = true;
                const cp = cp_iter.next().?;
                errdefer std.debug.print("cp_iter.i {d},  wanted: '{c}', got: '{c}'\n", .{
                    cp_iter.i,
                    @as(u8, @intCast(cp.code)),
                    @as(u8, @intCast(r.value)),
                });
                try eq(cp.code, r.value);
                try eq(iter.win.buf.langsuite.?.highlight_map.?.get(hl_group).?, r.color);
                try eq(start_x + (x_inc * @as(f32, @floatFromInt(cp_iter.i - 1))), r.x);
                try eq(y, r.y);
                if (cp_iter.peek() == null) return;
            },
            else => continue,
        }
    }
    eq(true, got_result) catch @panic("Expected batch result, got nothing!\n");
}

fn setupLangSuite(a: Allocator, lang_choice: sitter.SupportedLanguages) !sitter.LangSuite {
    var langsuite = try sitter.LangSuite.create(lang_choice);
    try langsuite.initializeQuery();
    try langsuite.initializeFilter(a);
    try langsuite.initializeHighlightMap(a);
    return langsuite;
}

fn setupBufAndWin(a: Allocator, langsuite: sitter.LangSuite, source: []const u8, font_size: i32, x: f32, y: f32, bounded: ?Window.Bounds) !*Window {
    var buf = try Buffer.create(a, .string, source);
    try buf.initiateTreeSitter(langsuite);
    return try Window.spawn(a, buf, font_size, x, y, bounded);
}

fn teardownWindow(win: *Window) void {
    win.buf.destroy();
    win.destroy();
}

////////////////////////////////////////////////////////////////////////////////////////////// For caller to provide font data

// Trimmed down versions of Raylib equivalents.
// Critical to calculate text positions.

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

fn setupFontDataAndIndexMap() !struct { FontData, FontDataIndexMap } {
    const a = idc_if_it_leaks;
    var file = try std.fs.cwd().openFile("src/window/font_data.json", .{});
    const json_str = try file.readToEndAlloc(a, 1024 * 1024 * 10);
    const font_data = try std.json.parseFromSlice(FontData, a, json_str, .{});
    const index_map = try createFontDataIndexMap(a, font_data.value);
    return .{ font_data.value, index_map };
}

pub const FontDataIndexMap = std.AutoHashMap(i32, usize);
pub fn createFontDataIndexMap(a: Allocator, font_data: FontData) !FontDataIndexMap {
    var map = FontDataIndexMap.init(a);
    for (0..font_data.glyphs.len) |i| try map.put(font_data.glyphs[i].value, i);
    return map;
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(Window);
    std.testing.refAllDeclsRecursive(Window.CodePointIterator);
}
