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

    pub fn cell(self: *const Line, cells: []const Cell, index: usize) ?Cell {
        if (self.numOfCells() == 0) return null;
        if (self.start + index > cells.len -| 1) return null;
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
        '-' => true,
        else => false,
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CharType = enum {
    space,
    word,
    symbol,
    null,

    fn fromChar(may_char: ?[]const u8) CharType {
        if (may_char) |char| {
            if (isSpace(char)) return .space;
            if (isSymbol(char)) return .symbol;
            return .word;
        }
        return .null;
    }
};

const WordBoundaryType = enum {
    start,
    end,
    both,
    not_a_boundary,
};

fn getCharBoundaryType(prev: ?[]const u8, curr: []const u8, next: ?[]const u8) WordBoundaryType {
    const curr_type = CharType.fromChar(curr);
    if (curr_type == .space) return .not_a_boundary;
    const prev_type = CharType.fromChar(prev);
    const next_type = CharType.fromChar(next);

    var curr_boundary_type: WordBoundaryType = .not_a_boundary;
    if (prev_type != curr_type) curr_boundary_type = .start;
    if (curr_type != next_type) {
        if (curr_boundary_type == .start) return .both;
        return .end;
    }

    return curr_boundary_type;
}

test getCharBoundaryType {
    try eq(.not_a_boundary, getCharBoundaryType("a", "b", "c"));
    try eq(.not_a_boundary, getCharBoundaryType("a", " ", "c"));
    try eq(.start, getCharBoundaryType(" ", "a", "c"));
    try eq(.start, getCharBoundaryType(";", "a", "c"));
    try eq(.end, getCharBoundaryType("a", "b", " "));
    try eq(.end, getCharBoundaryType("a", "b", ";"));
    try eq(.both, getCharBoundaryType(" ", "a", " "));
    try eq(.both, getCharBoundaryType(" ", "a", ";"));
}

fn foundTargetBoundary(source: []const u8, cells: []const Cell, curr_line: Line, colnr: usize, boundary_type: WordBoundaryType) bool {
    const prev_char = if (colnr == 0) null else curr_line.cell(cells, colnr - 1).?.getText(source);
    const curr_char = curr_line.cell(cells, colnr).?.getText(source);
    const next_char = if (curr_line.cell(cells, colnr + 1)) |c| c.getText(source) else null;
    const char_boundary_type = getCharBoundaryType(prev_char, curr_char, next_char);
    if (char_boundary_type == boundary_type or char_boundary_type == .both) return true;
    return false;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn moveCursorForward(
    destination: WordBoundaryType,
    source: []const u8,
    cells: []const Cell,
    lines: []const Line,
    input_linenr: usize,
    input_colnr: usize,
) struct { usize, usize } {
    var linenr, var colnr = bringLinenrAndColnrInBound(lines, input_linenr, input_colnr);
    if (linenr == lines.len -| 1 and colnr == lines[lines.len -| 1].numOfCells() -| 1) return .{ linenr, colnr };
    colnr += 1;
    while (true) {
        defer colnr += 1;
        if (colnr >= lines[linenr].numOfCells() -| 1) {
            if (linenr == lines.len - 1) return .{ linenr, colnr };
            linenr += 1;
            colnr = 0;
        }
        if (foundTargetBoundary(source, cells, lines[linenr], colnr, destination)) return .{ linenr, colnr };
    }
    return .{ linenr, colnr };
}

test moveCursorForward {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const source = "";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 0 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eq(.{ 0, 0 }, moveCursorForward(.start, source, cells, lines, 100, 0));
        try eq(.{ 0, 0 }, moveCursorForward(.start, source, cells, lines, 0, 200));
    }
    {
        const source = "hello world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr("w", lines[0].cell(cells, 6).?.getText(source));
        try eq(.{ 0, 10 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eqStr("d", lines[0].cell(cells, 10).?.getText(source));
    }
    {
        const source = "hello; world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 5 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr(";", lines[0].cell(cells, 5).?.getText(source));
        try eq(.{ 0, 7 }, moveCursorForward(.start, source, cells, lines, 0, 5));
        try eqStr("w", lines[0].cell(cells, 7).?.getText(source));
        try eq(.{ 0, 11 }, moveCursorForward(.start, source, cells, lines, 0, 7));
        try eqStr("d", lines[0].cell(cells, 11).?.getText(source));
    }
    {
        const source = "hello ; world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr(";", lines[0].cell(cells, 6).?.getText(source));
        try eq(.{ 0, 8 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eqStr("w", lines[0].cell(cells, 8).?.getText(source));
        try eq(.{ 0, 12 }, moveCursorForward(.start, source, cells, lines, 0, 8));
        try eqStr("d", lines[0].cell(cells, 12).?.getText(source));
    }
    {
        const source = "hello ;; world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr(";", lines[0].cell(cells, 6).?.getText(source));
        try eq(.{ 0, 9 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eqStr("w", lines[0].cell(cells, 9).?.getText(source));
        try eq(.{ 0, 13 }, moveCursorForward(.start, source, cells, lines, 0, 9));
        try eqStr("d", lines[0].cell(cells, 13).?.getText(source));
    }
    {
        const source = "hello  world";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 7 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr("w", lines[0].cell(cells, 7).?.getText(source));
        try eq(.{ 0, 11 }, moveCursorForward(.start, source, cells, lines, 0, 7));
        try eqStr("d", lines[0].cell(cells, 11).?.getText(source));
    }
    {
        const source = "hello   world one  two";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 8 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr("w", lines[0].cell(cells, 8).?.getText(source));
        try eq(.{ 0, 14 }, moveCursorForward(.start, source, cells, lines, 0, 8));
        try eqStr("o", lines[0].cell(cells, 14).?.getText(source));
        try eq(.{ 0, 19 }, moveCursorForward(.start, source, cells, lines, 0, 14));
        try eqStr("t", lines[0].cell(cells, 19).?.getText(source));
    }
    {
        const source = "one|two||3|||four";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 3 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eq(.{ 0, 3 }, moveCursorForward(.start, source, cells, lines, 0, 1));
        try eq(.{ 0, 3 }, moveCursorForward(.start, source, cells, lines, 0, 2));
        try eqStr("|", lines[0].cell(cells, 3).?.getText(source));
        try eq(.{ 0, 4 }, moveCursorForward(.start, source, cells, lines, 0, 3));
        try eqStr("t", lines[0].cell(cells, 4).?.getText(source));
        try eq(.{ 0, 7 }, moveCursorForward(.start, source, cells, lines, 0, 4));
        try eq(.{ 0, 7 }, moveCursorForward(.start, source, cells, lines, 0, 5));
        try eq(.{ 0, 7 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eqStr("|", lines[0].cell(cells, 7).?.getText(source));
        try eq(.{ 0, 9 }, moveCursorForward(.start, source, cells, lines, 0, 7));
        try eq(.{ 0, 9 }, moveCursorForward(.start, source, cells, lines, 0, 8));
        try eqStr("3", lines[0].cell(cells, 9).?.getText(source));
        try eq(.{ 0, 10 }, moveCursorForward(.start, source, cells, lines, 0, 9));
        try eqStr("|", lines[0].cell(cells, 10).?.getText(source));
        try eq(.{ 0, 13 }, moveCursorForward(.start, source, cells, lines, 0, 10));
        try eq(.{ 0, 13 }, moveCursorForward(.start, source, cells, lines, 0, 11));
        try eq(.{ 0, 13 }, moveCursorForward(.start, source, cells, lines, 0, 12));
        try eqStr("f", lines[0].cell(cells, 13).?.getText(source));
        try eq(.{ 0, 16 }, moveCursorForward(.start, source, cells, lines, 0, 13));
        try eq(.{ 0, 16 }, moveCursorForward(.start, source, cells, lines, 0, 14));
        try eq(.{ 0, 16 }, moveCursorForward(.start, source, cells, lines, 0, 15));
        try eq(.{ 0, 16 }, moveCursorForward(.start, source, cells, lines, 0, 16));
        try eqStr("r", lines[0].cell(cells, 16).?.getText(source));
    }
    {
        const source = "const std = @import(\"std\");\nconst";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eqStr("s", lines[0].cell(cells, 6).?.getText(source));
        try eq(.{ 0, 10 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eqStr("=", lines[0].cell(cells, 10).?.getText(source));
        try eq(.{ 0, 12 }, moveCursorForward(.start, source, cells, lines, 0, 10));
        try eqStr("@", lines[0].cell(cells, 12).?.getText(source));
        try eq(.{ 0, 19 }, moveCursorForward(.start, source, cells, lines, 0, 12));
        try eqStr("(", lines[0].cell(cells, 19).?.getText(source));
        try eq(.{ 0, 21 }, moveCursorForward(.start, source, cells, lines, 0, 19));
        try eqStr("s", lines[0].cell(cells, 21).?.getText(source));
        try eq(.{ 0, 24 }, moveCursorForward(.start, source, cells, lines, 0, 21));
        try eqStr("\"", lines[0].cell(cells, 24).?.getText(source));
        try eq(.{ 1, 0 }, moveCursorForward(.start, source, cells, lines, 0, 24));
        try eqStr("c", lines[1].cell(cells, 0).?.getText(source));
    }
    {
        const source = "hello\nworld\nvenus\nmars";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 1, 0 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eq(.{ 2, 0 }, moveCursorForward(.start, source, cells, lines, 1, 0));
        try eq(.{ 3, 0 }, moveCursorForward(.start, source, cells, lines, 2, 0));
    }
    {
        const source = "hello world\nvenus and mars";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 6 }, moveCursorForward(.start, source, cells, lines, 0, 0));
        try eq(.{ 1, 0 }, moveCursorForward(.start, source, cells, lines, 0, 6));
        try eq(.{ 1, 6 }, moveCursorForward(.start, source, cells, lines, 1, 0));
        try eqStr("a", lines[1].cell(cells, 6).?.getText(source));
        try eq(.{ 1, 10 }, moveCursorForward(.start, source, cells, lines, 1, 6));
        try eqStr("m", lines[1].cell(cells, 10).?.getText(source));
        try eq(.{ 1, 13 }, moveCursorForward(.start, source, cells, lines, 1, 10));
        try eqStr("s", lines[1].cell(cells, 13).?.getText(source));
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn moveCursorBackwards(
    destination: WordBoundaryType,
    source: []const u8,
    cells: []const Cell,
    lines: []const Line,
    input_linenr: usize,
    input_colnr: usize,
) struct { usize, usize } {
    var linenr, var colnr = bringLinenrAndColnrInBound(lines, input_linenr, input_colnr);
    colnr -|= 1;
    while (true) {
        defer colnr -|= 1;
        if (colnr == 0) {
            if (linenr == 0 or input_colnr > 0) return .{ linenr, colnr };
            linenr -= 1;
            colnr = lines[linenr].numOfCells() - 1;
        }
        if (foundTargetBoundary(source, cells, lines[linenr], colnr, destination)) return .{ linenr, colnr };
    }
    return .{ linenr, colnr };
}

test moveCursorBackwards {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const source = "";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 0));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 100, 0));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 200));
    }
    {
        const source = "one;two--3|||four;";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 13 }, moveCursorBackwards(.start, source, cells, lines, 0, 17));
        try eq(.{ 0, 13 }, moveCursorBackwards(.start, source, cells, lines, 0, 16));
        try eq(.{ 0, 13 }, moveCursorBackwards(.start, source, cells, lines, 0, 15));
        try eq(.{ 0, 13 }, moveCursorBackwards(.start, source, cells, lines, 0, 14));
        try eqStr("f", lines[0].cell(cells, 13).?.getText(source));
        try eq(.{ 0, 10 }, moveCursorBackwards(.start, source, cells, lines, 0, 13));
        try eq(.{ 0, 10 }, moveCursorBackwards(.start, source, cells, lines, 0, 12));
        try eq(.{ 0, 10 }, moveCursorBackwards(.start, source, cells, lines, 0, 11));
        try eqStr("|", lines[0].cell(cells, 10).?.getText(source));
        try eq(.{ 0, 9 }, moveCursorBackwards(.start, source, cells, lines, 0, 10));
        try eqStr("3", lines[0].cell(cells, 9).?.getText(source));
        try eq(.{ 0, 7 }, moveCursorBackwards(.start, source, cells, lines, 0, 9));
        try eq(.{ 0, 7 }, moveCursorBackwards(.start, source, cells, lines, 0, 8));
        try eqStr("-", lines[0].cell(cells, 7).?.getText(source));
        try eq(.{ 0, 4 }, moveCursorBackwards(.start, source, cells, lines, 0, 7));
        try eq(.{ 0, 4 }, moveCursorBackwards(.start, source, cells, lines, 0, 6));
        try eq(.{ 0, 4 }, moveCursorBackwards(.start, source, cells, lines, 0, 5));
        try eqStr("t", lines[0].cell(cells, 4).?.getText(source));
        try eq(.{ 0, 3 }, moveCursorBackwards(.start, source, cells, lines, 0, 4));
        try eqStr(";", lines[0].cell(cells, 3).?.getText(source));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 3));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 2));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 1));
        try eqStr("o", lines[0].cell(cells, 0).?.getText(source));
    }

    {
        const source = "one\ntwo";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 1, 0 }, moveCursorBackwards(.start, source, cells, lines, 1, 2));
        try eq(.{ 1, 0 }, moveCursorBackwards(.start, source, cells, lines, 1, 1));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 1, 0));
    }
    {
        const source = "draw forth\na map";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 1, 2 }, moveCursorBackwards(.start, source, cells, lines, 1, 4));
        try eq(.{ 1, 2 }, moveCursorBackwards(.start, source, cells, lines, 1, 3));
        try eqStr("m", lines[1].cell(cells, 2).?.getText(source));
        try eq(.{ 1, 0 }, moveCursorBackwards(.start, source, cells, lines, 1, 2));
        try eq(.{ 1, 0 }, moveCursorBackwards(.start, source, cells, lines, 1, 1));
        try eqStr("a", lines[1].cell(cells, 0).?.getText(source));
        try eq(.{ 0, 5 }, moveCursorBackwards(.start, source, cells, lines, 1, 0));
        try eqStr("f", lines[0].cell(cells, 5).?.getText(source));
        try eq(.{ 0, 0 }, moveCursorBackwards(.start, source, cells, lines, 0, 5));
        try eqStr("d", lines[0].cell(cells, 0).?.getText(source));
    }
    {
        const source = "draw forth;\na map";
        const cells, const lines = try createCellSliceAndLineSlice(a, source);
        try eq(.{ 0, 10 }, moveCursorBackwards(.start, source, cells, lines, 1, 0));
        try eqStr(";", lines[0].cell(cells, 10).?.getText(source));
        try eq(.{ 0, 5 }, moveCursorBackwards(.start, source, cells, lines, 0, 10));
    }
}
