const std = @import("std");
const _nc = @import("neo_cell.zig");
const _buf_mod = @import("neo_buffer");
const ztracy = @import("ztracy");
pub const Buffer = _buf_mod.Buffer;
pub const sitter = _buf_mod.sitter;
const ts = sitter.b;

const _ip = @import("input_processor");
const Callback = _ip.Callback;
const Key = _ip.Key;
const MappingCouncil = _ip.MappingCouncil;

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
    contents: Contents = undefined,

    cursor: Cursor,
    visual_mode_cursor: Cursor,

    x: f32,
    y: f32,
    bounds: Bounds,
    bounded: bool,

    font_size: i32,
    line_spacing: i32 = 2,

    // TODO: find a better name for this field.
    is_in_AFTER_insert_mode: bool = false,

    const Cursor = struct {
        line: usize = 0,
        col: usize = 0,

        pub fn set(self: *Cursor, line: usize, col: usize) void {
            self.line = line;
            self.col = col;
        }
    };

    pub const Bounds = struct {
        width: f32 = 400,
        height: f32 = 400,
        offset: struct { x: f32, y: f32 } = .{ .x = 0, .y = 0 },
    };

    /// A slice of `[]const u8` values. Each `[]const u8` represents a single character,
    /// regardless of its byte length.
    const Line = []u21;

    /// A slice of `u32` values. Each `u32` represents an RGBA color.
    const LineColors = []u32;

    /// Holds text content and color content for each line that Window holds.
    /// Window can hold more contents than it can display.
    /// Let's say Window height makes it can only display 40 lines,
    /// but internally it can hold say for example 80 lines, 400 lines, etc...
    /// The number of lines a Window should hold is still being worked on.
    const Contents = struct {
        window: *Window,
        lines: ArrayList(Line),
        line_colors: ArrayList(LineColors),
        start_line: usize,
        end_line: usize,

        fn createWithCapacity(win: *Window, start_line: usize, num_of_lines: usize) !Contents {
            const lines, const line_colors = try createLines(win, start_line, num_of_lines);
            return .{
                .window = win,
                .start_line = start_line,
                .end_line = start_line + num_of_lines -| 1,
                .lines = lines,
                .line_colors = line_colors,
            };
        }

        fn updateLines(self: *@This(), old_start_line: usize, old_end_line: usize, new_start_line: usize, new_end_line: usize) !void {
            var new_lines, var new_line_colors = try createLines(self.window, new_start_line, new_end_line -| new_start_line + 1);
            defer new_lines.deinit();
            defer new_line_colors.deinit();

            for (old_start_line..old_end_line + 1) |i| {
                self.window.exa.free(self.lines.items[i]);
                self.window.exa.free(self.line_colors.items[i]);
            }

            try self.lines.replaceRange(old_start_line, old_end_line -| old_start_line + 1, new_lines.items);
            try self.line_colors.replaceRange(old_start_line, old_end_line -| old_start_line + 1, new_line_colors.items);

            self.end_line = self.start_line + self.lines.items.len -| 1;
        }

        fn createLines(win: *Window, start_line: usize, num_of_lines: usize) !struct { ArrayList(Line), ArrayList(LineColors) } {
            const method_zone = ztracy.ZoneNC(@src(), "Contents.createLines()", 0x0999FF);
            defer method_zone.End();
            method_zone.Value(@intCast(num_of_lines));

            const end_line = start_line + num_of_lines -| 1;

            // add lines
            var lines = try ArrayList(Line).initCapacity(win.exa, num_of_lines);
            for (start_line..start_line + num_of_lines) |linenr| {
                const line = try win.buf.roperoot.getLineEx(win.exa, linenr);
                try lines.append(line);
            }

            // add default color
            const add_default_color_zone = ztracy.ZoneNC(@src(), "add default color", 0x00FFAA);
            var line_colors = try ArrayList(LineColors).initCapacity(win.exa, num_of_lines);
            for (lines.items) |line| {
                const colors = try win.exa.alloc(u32, line.len);
                @memset(colors, 0xF5F5F5F5);
                try line_colors.append(colors);
            }
            add_default_color_zone.End();

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
                            const end_col = if (linenr == node_end.row) node_end.column else lines.items[line_index].len;
                            @memset(line_colors.items[line_index][start_col..end_col], color);
                        }
                    }
                }
            }

            return .{ lines, line_colors };
        }

        fn destroy(self: *@This()) void {
            for (self.lines.items) |line| self.window.exa.free(line);
            for (self.line_colors.items) |lc| self.window.exa.free(lc);
            self.lines.deinit();
            self.line_colors.deinit();
        }
    };

    pub const SpawnOptions = struct {
        font_size: i32,
        x: f32,
        y: f32,
        bounds: ?Bounds = null,
    };

    pub fn spawn(exa: Allocator, buf: *Buffer, opts: SpawnOptions) !*@This() {
        const self = try exa.create(@This());
        self.* = .{
            .exa = exa,
            .buf = buf,
            .cursor = Cursor{},
            .visual_mode_cursor = Cursor{},
            .x = opts.x,
            .y = opts.y,
            .bounded = if (opts.bounds != null) true else false,
            .bounds = if (opts.bounds) |b| b else Bounds{},
            .font_size = opts.font_size,
        };
        try self.updateContents(buf);
        return self;
    }

    pub fn changeBuffer(self: *@This(), new_buf: *Buffer) !void {
        // TODO: maybe have a `hidden buffers` feature like Vim in the future.
        self.buf.destroy();

        self.contents.destroy();
        self.buf = new_buf;
        try self.updateContents(new_buf);
    }

    pub fn destroy(self: *@This()) void {
        self.contents.destroy();
        self.exa.destroy(self);
    }

    fn updateContents(self: *@This(), buf: *Buffer) !void {
        // store the content of the entire buffer for now,
        // we'll explore more delicate solutions after we deal with scissor mode.
        const start_line = 0;
        const num_of_lines = buf.roperoot.weights().bols;
        self.contents = try Contents.createWithCapacity(self, start_line, num_of_lines);
    }

    ///////////////////////////// Get Window Width & Height

    pub fn getWidth(self: *const @This(), font_data: FontData, index_map: FontDataIndexMap) f32 {
        var win_width: f32 = 0;
        for (self.contents.lines.items) |line| {
            var line_width: f32 = 0;
            for (line) |char| {
                const cp_i32: i32 = @intCast(char);
                const glyph_index = index_map.get(cp_i32) orelse @panic("CodePoint doesn't exist in Font!");
                var char_width: f32 = @floatFromInt(font_data.glyphs[glyph_index].advanceX);
                if (char_width == 0) char_width = font_data.recs[glyph_index].width + @as(f32, @floatFromInt(font_data.glyphs[glyph_index].offsetX));
                line_width += char_width;
            }
            win_width = @max(win_width, line_width);
        }
        return win_width;
    }

    pub fn getHeight(self: *const @This()) f32 {
        return @as(f32, @floatFromInt(self.contents.lines.items.len)) * self.getLineHeight();
    }

    fn getLineHeight(self: *const @This()) f32 {
        return @floatFromInt(self.font_size + self.line_spacing);
    }

    ///////////////////////////// Window Position & Bounds

    pub fn toggleBounds(self: *@This()) void {
        self.bounded = !self.bounded;
    }

    ///////////////////////////// Insert Chars

    pub fn insertChars(self: *@This(), chars: []const u8) !void {
        const zone = ztracy.ZoneNC(@src(), "insertChars()", 0xAAAAFF);
        defer zone.End();

        var start_line = self.cursor.line;

        const new_pos, const may_ranges = try self.buf.insertChars(chars, self.cursor.line, self.cursor.col);
        self.cursor.set(new_pos.line, new_pos.col);

        var end_line = new_pos.line;

        if (may_ranges) |ranges| {
            for (ranges) |range| {
                const ts_start_row: usize = @intCast(range.start_point.row);
                const ts_end_row: usize = @intCast(range.end_point.row);
                start_line = @min(start_line, ts_start_row);
                end_line = @max(end_line, ts_end_row);
            }
        }

        try self.contents.updateLines(start_line, end_line, start_line, end_line);
    }

    pub const InsertCharsCb = struct {
        chars: []const u8,
        target: *Window,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.insertChars(self.chars);
        }
        pub fn init(allocator: Allocator, target: *Window, chars: []const u8) !Callback {
            const self = try allocator.create(@This());
            self.* = .{ .chars = chars, .target = target };
            return Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };

    const Pair = struct { []const Key, []const u8 };
    const pairs = [_]Pair{
        .{ &.{.a}, "a" },             .{ &.{ .left_shift, .a }, "A" },             .{ &.{ .right_shift, .a }, "A" },
        .{ &.{.b}, "b" },             .{ &.{ .left_shift, .b }, "B" },             .{ &.{ .right_shift, .b }, "B" },
        .{ &.{.c}, "c" },             .{ &.{ .left_shift, .c }, "C" },             .{ &.{ .right_shift, .c }, "C" },
        .{ &.{.d}, "d" },             .{ &.{ .left_shift, .d }, "D" },             .{ &.{ .right_shift, .d }, "D" },
        .{ &.{.e}, "e" },             .{ &.{ .left_shift, .e }, "E" },             .{ &.{ .right_shift, .e }, "E" },
        .{ &.{.f}, "f" },             .{ &.{ .left_shift, .f }, "F" },             .{ &.{ .right_shift, .f }, "F" },
        .{ &.{.g}, "g" },             .{ &.{ .left_shift, .g }, "G" },             .{ &.{ .right_shift, .g }, "G" },
        .{ &.{.h}, "h" },             .{ &.{ .left_shift, .h }, "H" },             .{ &.{ .right_shift, .h }, "H" },
        .{ &.{.i}, "i" },             .{ &.{ .left_shift, .i }, "I" },             .{ &.{ .right_shift, .i }, "I" },
        .{ &.{.j}, "j" },             .{ &.{ .left_shift, .j }, "J" },             .{ &.{ .right_shift, .j }, "J" },
        .{ &.{.k}, "k" },             .{ &.{ .left_shift, .k }, "K" },             .{ &.{ .right_shift, .k }, "K" },
        .{ &.{.l}, "l" },             .{ &.{ .left_shift, .l }, "L" },             .{ &.{ .right_shift, .l }, "L" },
        .{ &.{.m}, "m" },             .{ &.{ .left_shift, .m }, "M" },             .{ &.{ .right_shift, .m }, "M" },
        .{ &.{.n}, "n" },             .{ &.{ .left_shift, .n }, "N" },             .{ &.{ .right_shift, .n }, "N" },
        .{ &.{.o}, "o" },             .{ &.{ .left_shift, .o }, "O" },             .{ &.{ .right_shift, .o }, "O" },
        .{ &.{.p}, "p" },             .{ &.{ .left_shift, .p }, "P" },             .{ &.{ .right_shift, .p }, "P" },
        .{ &.{.q}, "q" },             .{ &.{ .left_shift, .q }, "Q" },             .{ &.{ .right_shift, .q }, "Q" },
        .{ &.{.r}, "r" },             .{ &.{ .left_shift, .r }, "R" },             .{ &.{ .right_shift, .r }, "R" },
        .{ &.{.s}, "s" },             .{ &.{ .left_shift, .s }, "S" },             .{ &.{ .right_shift, .s }, "S" },
        .{ &.{.t}, "t" },             .{ &.{ .left_shift, .t }, "T" },             .{ &.{ .right_shift, .t }, "T" },
        .{ &.{.u}, "u" },             .{ &.{ .left_shift, .u }, "U" },             .{ &.{ .right_shift, .u }, "U" },
        .{ &.{.v}, "v" },             .{ &.{ .left_shift, .v }, "V" },             .{ &.{ .right_shift, .v }, "V" },
        .{ &.{.w}, "w" },             .{ &.{ .left_shift, .w }, "W" },             .{ &.{ .right_shift, .w }, "W" },
        .{ &.{.x}, "x" },             .{ &.{ .left_shift, .x }, "X" },             .{ &.{ .right_shift, .x }, "X" },
        .{ &.{.y}, "y" },             .{ &.{ .left_shift, .y }, "Y" },             .{ &.{ .right_shift, .y }, "Y" },
        .{ &.{.z}, "z" },             .{ &.{ .left_shift, .z }, "Z" },             .{ &.{ .right_shift, .z }, "Z" },
        .{ &.{.one}, "1" },           .{ &.{ .left_shift, .one }, "!" },           .{ &.{ .right_shift, .one }, "!" },
        .{ &.{.two}, "2" },           .{ &.{ .left_shift, .two }, "@" },           .{ &.{ .right_shift, .two }, "@" },
        .{ &.{.three}, "3" },         .{ &.{ .left_shift, .three }, "#" },         .{ &.{ .right_shift, .three }, "#" },
        .{ &.{.four}, "4" },          .{ &.{ .left_shift, .four }, "$" },          .{ &.{ .right_shift, .four }, "$" },
        .{ &.{.five}, "5" },          .{ &.{ .left_shift, .five }, "%" },          .{ &.{ .right_shift, .five }, "%" },
        .{ &.{.six}, "6" },           .{ &.{ .left_shift, .six }, "^" },           .{ &.{ .right_shift, .six }, "^" },
        .{ &.{.seven}, "7" },         .{ &.{ .left_shift, .seven }, "&" },         .{ &.{ .right_shift, .seven }, "&" },
        .{ &.{.eight}, "8" },         .{ &.{ .left_shift, .eight }, "*" },         .{ &.{ .right_shift, .eight }, "*" },
        .{ &.{.nine}, "9" },          .{ &.{ .left_shift, .nine }, "(" },          .{ &.{ .right_shift, .nine }, "(" },
        .{ &.{.zero}, "0" },          .{ &.{ .left_shift, .zero }, ")" },          .{ &.{ .right_shift, .zero }, ")" },
        .{ &.{.equal}, "=" },         .{ &.{ .left_shift, .equal }, "+" },         .{ &.{ .right_shift, .equal }, "+" },
        .{ &.{.comma}, "," },         .{ &.{ .left_shift, .comma }, "<" },         .{ &.{ .right_shift, .comma }, "<" },
        .{ &.{.period}, "." },        .{ &.{ .left_shift, .period }, ">" },        .{ &.{ .right_shift, .period }, ">" },
        .{ &.{.slash}, "/" },         .{ &.{ .left_shift, .slash }, "?" },         .{ &.{ .right_shift, .slash }, "?" },
        .{ &.{.semicolon}, ";" },     .{ &.{ .left_shift, .semicolon }, ":" },     .{ &.{ .right_shift, .semicolon }, ":" },
        .{ &.{.apostrophe}, "'" },    .{ &.{ .left_shift, .apostrophe }, "\"" },   .{ &.{ .right_shift, .apostrophe }, "\"" },
        .{ &.{.backslash}, "\\" },    .{ &.{ .left_shift, .backslash }, "|" },     .{ &.{ .right_shift, .backslash }, "|" },
        .{ &.{.left_bracket}, "[" },  .{ &.{ .left_shift, .left_bracket }, "{" },  .{ &.{ .right_shift, .left_bracket }, "{" },
        .{ &.{.right_bracket}, "]" }, .{ &.{ .left_shift, .right_bracket }, "}" }, .{ &.{ .right_shift, .right_bracket }, "}" },
        .{ &.{.grave}, "`" },         .{ &.{ .left_shift, .grave }, "~" },         .{ &.{ .right_shift, .grave }, "~" },
        .{ &.{.space}, " " },         .{ &.{ .left_shift, .space }, " " },         .{ &.{ .right_shift, .space }, " " },
    };
    pub fn mapInsertModeCharacters(self: *@This(), council: *_ip.MappingCouncil) !void {
        for (0..pairs.len) |i| {
            const keys, const chars = pairs[i];
            try council.map("insert", keys, try InsertCharsCb.init(council.arena.allocator(), self, chars));
        }
    }

    ///////////////////////////// Enter / Exit Insert Mode

    pub fn enterAFTERInsertMode(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.is_in_AFTER_insert_mode = true;
        try moveCursorRight(self);
    }

    pub fn exitInsertMode(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.is_in_AFTER_insert_mode = false;
        try moveCursorLeft(self);
    }

    pub fn capitalA(ctx: *anyopaque) !void {
        try moveCursorToEndOfLine(ctx);
        try enterAFTERInsertMode(ctx);
    }

    ///////////////////////////// Baclspace & Delete

    pub fn backspace(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        if (self.cursor.line == 0 and self.cursor.col == 0) return;

        var start_line: usize = self.cursor.line;
        var start_col: usize = self.cursor.col -| 1;
        var end_line: usize = self.cursor.line;
        const end_col: usize = self.cursor.col;

        if (self.cursor.col == 0 and self.cursor.line > 0) {
            start_line = self.cursor.line - 1;
            start_col = self.contents.lines.items[start_line].len;
        }

        const may_ranges = try self.buf.deleteRange(.{ start_line, start_col }, .{ end_line, end_col });
        self.cursor.set(start_line, start_col);

        if (may_ranges) |ranges| {
            for (ranges) |range| {
                const ts_start_row: usize = @intCast(range.start_point.row);
                const ts_end_row: usize = @intCast(range.end_point.row);
                start_line = @min(start_line, ts_start_row);
                end_line = @max(end_line, ts_end_row);
            }
        }

        try self.contents.updateLines(start_line, end_line, start_line, start_line);
    }

    ///////////////////////////// Visual Mode

    pub fn enterVisualMode(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.visual_mode_cursor = self.cursor;
    }

    ///////////////////////////// Directional Cursor Movement

    pub fn moveCursorToBeginningOfLine(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.col = 0;
    }

    pub fn moveCursorToFirstNonBlankChar(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.col = 0;
        if (self.contents.lines.items[self.cursor.line].len == 0) return;
        const first_char = self.contents.lines.items[self.cursor.line][0];
        if (!_nc.isSpace(first_char)) return;
        try vimForwardStart(self);
    }

    pub fn moveCursorToEndOfLine(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.col = self.contents.lines.items[self.cursor.line].len;
        self.restrictCursorInView(&self.cursor);
    }

    pub fn moveCursorLeft(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.col -|= 1;
        self.restrictCursorInView(&self.cursor);
    }

    pub fn moveCursorUp(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.line -|= 1;
        self.restrictCursorInView(&self.cursor);
    }

    pub fn moveCursorRight(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.col += 1;
        self.restrictCursorInView(&self.cursor);
    }

    pub fn moveCursorDown(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.cursor.line += 1;
        self.restrictCursorInView(&self.cursor);
    }

    fn restrictCursorInView(self: *@This(), cursor: *Cursor) void {
        if (cursor.line < self.contents.start_line) cursor.line = self.contents.start_line;
        if (cursor.line > self.contents.end_line) cursor.line = self.contents.end_line;
        const current_line_index = cursor.line - self.contents.start_line;
        const current_line = self.contents.lines.items[current_line_index];
        if (current_line.len == 0) cursor.col = 0;

        const offset: usize = if (self.is_in_AFTER_insert_mode) 0 else 1;
        if (cursor.col > current_line.len -| offset) cursor.col = current_line.len -| 1;
    }

    ///////////////////////////// Vim Cursor Movement

    pub fn vimBackwards(self: *@This(), boundary_type: _nc.WordBoundaryType, cursor: *Cursor) void {
        const line, const col = _nc.backwardsByWord(boundary_type, self.contents.lines.items, cursor.line, cursor.col);
        cursor.set(line, col);
    }

    pub fn vimForward(self: *@This(), boundary_type: _nc.WordBoundaryType, cursor: *Cursor) void {
        const line, const col = _nc.forwardByWord(boundary_type, self.contents.lines.items, cursor.line, cursor.col);
        cursor.set(line, col);
    }

    pub fn vimForwardStart(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.vimForward(.start, &self.cursor);
    }

    pub fn vimForwardEnd(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.vimForward(.end, &self.cursor);
    }

    pub fn vimBackwardsStart(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        self.vimBackwards(.start, &self.cursor);
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
            char_width: f32,
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
            if (self.current_y + self.win.getLineHeight() <= self.screen.start_y) return self.advanceToNextLine();

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
                if (self.current_y + self.win.getLineHeight() < self.win.y) return self.advanceToNextLine();
            }

            // col check
            if (self.currentColOutOfBounds()) return self.advanceToNextLine();

            // get code point
            const char = self.win.contents.lines.items[self.current_line][self.current_col];
            const cp_i32: i32 = @intCast(char);

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
                .color = self.win.contents.line_colors.items[self.current_line][self.current_col],
                .x = self.current_x,
                .y = self.current_y,
                .char_width = char_width,
                .font_size = self.win.font_size,
            } };
        }

        fn currentColOutOfBounds(self: *@This()) bool {
            return self.current_col >= self.win.contents.lines.items[self.current_line].len;
        }

        fn currentLineOutOfBounds(self: *@This()) bool {
            return self.current_line >= self.win.contents.lines.items.len;
        }

        fn advanceToNextLine(self: *@This()) IterResult {
            self.current_line += 1;
            self.current_col = 0;
            self.current_x = self.win.x;
            if (self.win.bounded) self.current_x -= self.win.bounds.offset.x;
            self.current_y += self.win.getLineHeight();
            return .skip_to_new_line;
        }
    };

    pub fn codePointIter(self: *@This(), font_data: FontData, index_map: FontDataIndexMap, screen: CodePointIterator.Screen) CodePointIterator {
        return CodePointIterator.create(self, font_data, index_map, screen);
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// CodePointIterator

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
    var cp_iter = _buf_mod.code_point.Iterator{ .bytes = sequence };
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

fn setupBufAndWin(a: Allocator, langsuite: sitter.LangSuite, source: []const u8, font_size: i32, x: f32, y: f32, bounds: ?Window.Bounds) !*Window {
    var buf = try Buffer.create(a, .string, source);
    try buf.initiateTreeSitter(langsuite);
    return try Window.spawn(a, buf, Window.SpawnOptions{ .font_size = font_size, .x = x, .y = y, .bounds = bounds });
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
