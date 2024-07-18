const std = @import("std");
const code_point = @import("code_point");

const List = std.ArrayList;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Cell = struct {
    start_byte: usize,
    end_byte: usize,

    pub fn len(self: *const Cell) usize {
        return self.end_byte - self.start_byte;
    }

    pub fn getText(self: *const Cell, source: []const u8) []const u8 {
        return source[self.start_byte..self.end_byte];
    }
};

pub const Line = struct {
    start: usize,
    end: usize,

    pub fn cell(self: *const Line, cells: []Cell, index: usize) ?Cell {
        if (self.numOfCells() == 0) return null;
        if (self.start + index > self.numOfCells() -| 1) return null;
        return cells[self.start + index];
    }

    pub fn getCells(self: *const Line, cells: []const Cell) []const Cell {
        return cells[self.start..self.end];
    }

    pub fn getText(self: *const Line, cells: []const Cell, source: []const u8) []const u8 {
        const line_cells = cells[self.start..self.end];
        return source[line_cells[0].start_byte..line_cells[line_cells.len - 1].end_byte];
    }

    pub fn numOfBytes(self: *const Line, cells: []const Cell) usize {
        const line_cells = self.getCells(cells);
        const start_byte = line_cells[0].start_byte;
        const end_byte = line_cells[line_cells.len - 1].end_byte;
        return end_byte - start_byte;
    }

    pub fn numOfCells(self: *const Line) usize {
        return self.end - self.start;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn createCellListAndLineList(a: Allocator, source: []const u8) !struct { List(Cell), List(Line) } {
    var cells = List(Cell).init(a);
    var lines = List(Line).init(a);

    var iter = code_point.Iterator{ .bytes = source };
    var i: usize = 0;
    while (iter.next()) |cp| {
        try cells.append(Cell{ .start_byte = cp.offset, .end_byte = cp.offset + cp.len });
        if (cp.code == '\n') {
            try lines.append(Line{ .start = i, .end = cells.items.len - 1 });
            i = cells.items.len;
        }
    }
    try lines.append(Line{ .start = i, .end = cells.items.len });

    return .{ cells, lines };
}

fn createCellSliceAndLineSlice(a: Allocator, source: []const u8) !struct { []Cell, []Line } {
    var cells, var lines = try createCellListAndLineList(a, source);
    return .{ try cells.toOwnedSlice(), try lines.toOwnedSlice() };
}

test createCellListAndLineList {
    const a = std.testing.allocator;
    const source = "안녕하세요!\nHello there 👋!";
    const cells, const lines = try createCellListAndLineList(a, source);
    defer cells.deinit();
    defer lines.deinit();

    try eqStr("안", cells.items[0].getText(source));
    try eqStr("\n", cells.items[6].getText(source));
    try eqStr("!", cells.items[cells.items.len - 1].getText(source));
    try eqStr("👋", cells.items[cells.items.len - 2].getText(source));

    try eq(2, lines.items.len);
    try eqStr("안녕하세요!", lines.items[0].getText(cells.items, source));
    try eqStr("Hello there 👋!", lines.items[1].getText(cells.items, source));
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn isNotWordChar(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
        ' ' => true,
        '=' => true,
        '"' => true,
        '\'' => true,
        '\t' => true,
        '\n' => true,
        '/' => true,
        '\\' => true,
        '*' => true,
        ':' => true,
        '.' => true,
        ',' => true,
        '(' => true,
        ')' => true,
        '{' => true,
        '}' => true,
        '[' => true,
        ']' => true,
        ';' => true,
        '|' => true,
        '?' => true,
        '&' => true,
        '#' => true,
        else => false,
    };
}

fn moveCursorForwardLikeVimOld(source: []const u8, cells: []const Cell, lines: []const Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    const last_line_index = lines.len - 1;
    const last_line = lines[last_line_index];
    const last_line_cells = last_line.getCells(cells);
    const default_result = .{ lines.len - 1, last_line_cells.len };
    if (input_linenr > last_line_index) return default_result;
    if (input_linenr == last_line_index and input_colnr >= last_line_cells.len) return default_result;

    var linenr = input_linenr;
    var colnr = input_colnr;
    var found_non_word = false;
    var passed_a_space = false;
    const start = lines[input_linenr].start + input_colnr;
    const start_is_word = !isNotWordChar(cells[start].getText(source));
    for (cells[start..cells.len], start..) |cell, i| {
        if (i < cells.len - 1 and lines[linenr].end - 1 == i) {
            linenr += 1;
            colnr = 0;
            return .{ linenr, colnr };
        }

        const char = cell.getText(source);
        if (found_non_word) {
            if (!isSpace(char) and !passed_a_space and start_is_word) return .{ linenr, colnr - 1 };
            if (!isNotWordChar(char)) return .{ linenr, colnr };
            if (!isSpace(char) and passed_a_space) return .{ linenr, colnr };
        }

        if (isNotWordChar(char)) found_non_word = true;
        if (isSpace(char)) passed_a_space = true;

        if (i == cells.len - 1 and found_non_word and start_is_word and !isSpace(char)) return .{ linenr, colnr };

        colnr += 1;
    }

    return default_result;
}

test moveCursorForwardLikeVimOld {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const source = "";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 100, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 12));
    }

    {
        const source = "hello world";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 100, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 12));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
    }

    {
        const source =
            \\hello
            \\world wide web
        ;
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 1, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 1, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 1, 0));
        try eq(.{ 1, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 1, 6));
    }

    {
        const source = "a b c d eee ffff";
        const cells, const lines = try createCellListAndLineList(a, source);

        try eq(.{ 0, 2 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 4 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 2));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 4));
        try eq(.{ 0, 8 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 8));

        try eq(.{ 0, 2 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 1));
        try eq(.{ 0, 4 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 3));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 5));
        try eq(.{ 0, 8 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 7));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 9));
    }

    {
        const source = "hello  world";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 7 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 7));
    }

    {
        const source = "const four = 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 13 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four     = 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 17 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 15));
    }

    {
        const source = "const four == 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 14 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four === 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four === #four";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 16));
    }

    {
        const source = "const four === #four;";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 16));
    }

    {
        const source = "const four === #four;a bbb\nvar something\nvar;";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 16));
        try eq(.{ 0, 21 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 20));
        try eq(.{ 0, 23 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 21));
        try eq(.{ 1, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 0, 23));
        try eq(.{ 1, 4 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 1, 0));
        try eq(.{ 2, 0 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 1, 4));
        try eq(.{ 2, 3 }, moveCursorForwardLikeVimOld(source, cells.items, lines.items, 2, 0));
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn bringLinenrAndColnrInBound(lines: []const Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    var linenr, var colnr = .{ input_linenr, input_colnr };
    if (linenr > lines.len -| 1) {
        linenr = lines.len -| 1;
        colnr = lines[linenr].numOfCells() -| 1;
        return .{ linenr, colnr };
    }
    if (colnr > lines[linenr].numOfCells() -| 1) colnr = lines[linenr].numOfCells() -| 1;
    return .{ linenr, colnr };
}

test bringLinenrAndColnrInBound {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        _, const lines = try createCellListAndLineList(a, "");
        try eq(.{ 0, 0 }, bringLinenrAndColnrInBound(lines.items, 0, 100));
        try eq(.{ 0, 0 }, bringLinenrAndColnrInBound(lines.items, 100, 0));
        try eq(.{ 0, 0 }, bringLinenrAndColnrInBound(lines.items, 200, 200));
    }
    {
        const cells, const lines = try createCellListAndLineList(a, "1234567890");
        try eq(10, lines.items[0].getCells(cells.items).len);
        try eq(.{ 0, 9 }, bringLinenrAndColnrInBound(lines.items, 0, 100));
        try eq(.{ 0, 9 }, bringLinenrAndColnrInBound(lines.items, 100, 0));
        try eq(.{ 0, 9 }, bringLinenrAndColnrInBound(lines.items, 100, 100));
        try eq(.{ 0, 9 }, bringLinenrAndColnrInBound(lines.items, 1, 5));
        try eq(.{ 0, 5 }, bringLinenrAndColnrInBound(lines.items, 0, 5));
    }
    {
        const cells, const lines = try createCellListAndLineList(a, "12345\n6789");
        try eq(5, lines.items[0].getCells(cells.items).len);
        try eq(4, lines.items[1].getCells(cells.items).len);
        try eq(.{ 0, 0 }, bringLinenrAndColnrInBound(lines.items, 0, 0));
        try eq(.{ 0, 4 }, bringLinenrAndColnrInBound(lines.items, 0, 10));
        try eq(.{ 0, 4 }, bringLinenrAndColnrInBound(lines.items, 0, 5));
        try eq(.{ 1, 0 }, bringLinenrAndColnrInBound(lines.items, 1, 0));
        try eq(.{ 1, 2 }, bringLinenrAndColnrInBound(lines.items, 1, 2));
        try eq(.{ 1, 3 }, bringLinenrAndColnrInBound(lines.items, 1, 3));
        try eq(.{ 1, 3 }, bringLinenrAndColnrInBound(lines.items, 1, 4));
        try eq(.{ 1, 3 }, bringLinenrAndColnrInBound(lines.items, 1, 100));
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn isSpace(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
        ' ' => true,
        '\t' => true,
        else => false,
    };
}

fn isSymbol(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
        '=' => true,
        '"' => true,
        '\'' => true,
        '\n' => true,
        '/' => true,
        '\\' => true,
        '*' => true,
        ':' => true,
        '.' => true,
        ',' => true,
        '(' => true,
        ')' => true,
        '{' => true,
        '}' => true,
        '[' => true,
        ']' => true,
        ';' => true,
        '|' => true,
        '?' => true,
        '&' => true,
        '#' => true,
        else => false,
    };
}

const TargetBoundary = enum {
    null,
    word,
    symbol,

    fn isSameTypeAs(self: TargetBoundary, char: []const u8) bool {
        return switch (self) {
            .symbol => isSymbol(char),
            .word => !isSymbol(char),
            else => false,
        };
    }
};

fn moveCursorForwardLikeVim(source: []const u8, cells: []const Cell, lines: []const Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    const linenr, var colnr = bringLinenrAndColnrInBound(lines, input_linenr, input_colnr);

    const start = lines[linenr].start + colnr;
    var target_boundary = TargetBoundary.null;
    var passed_a_space = false;
    for (start..cells.len) |i| {
        defer colnr += 1;

        const char = cells[i].getText(source);
        // std.debug.print("char: {s}\n", .{char});

        if (isSpace(char)) {
            passed_a_space = true;
            target_boundary = .null;
            continue;
        }

        if (target_boundary == .null) {
            if (passed_a_space) {
                return .{ linenr, colnr };
            }
            target_boundary = if (isSymbol(char)) .word else .symbol;
            continue;
        }

        if (target_boundary.isSameTypeAs(char)) {
            return .{ linenr, colnr };
        }
    }

    return .{ linenr, colnr -| 1 };
}

test moveCursorForwardLikeVim {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const source = "";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells, lines, 0, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells, lines, 100, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells, lines, 0, 200));
    }

    {
        const source = "hello world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells, lines, 0, 0));
        try eqStr("w", lines[0].cell(cells, 6).?.getText(source));
        try eq(.{ 0, 10 }, moveCursorForwardLikeVim(source, cells, lines, 0, 6));
        try eqStr("d", lines[0].cell(cells, 10).?.getText(source));
    }
}
