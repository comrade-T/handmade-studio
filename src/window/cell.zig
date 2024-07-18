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

    pub fn len(self: *const @This()) usize {
        return self.end_byte - self.start_byte;
    }

    pub fn getText(self: *const Cell, source: []const u8) []const u8 {
        return source[self.start_byte..self.end_byte];
    }
};

pub const Line = struct {
    start: usize,
    end: usize,

    pub fn getCells(self: *const @This(), cells: []const Cell) []const Cell {
        return cells[self.start..self.end];
    }

    pub fn getText(self: *const @This(), cells: []const Cell, source: []const u8) []const u8 {
        const line_cells = cells[self.start..self.end];
        return source[line_cells[0].start_byte..line_cells[line_cells.len - 1].end_byte];
    }

    pub fn numOfBytes(self: *const @This(), cells: []const Cell) usize {
        const line_cells = self.getCells(cells);
        const start_byte = line_cells[0].start_byte;
        const end_byte = line_cells[line_cells.len - 1].end_byte;
        return end_byte - start_byte;
    }

    pub fn numOfCells(self: *const @This()) usize {
        return self.end - self.start;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

fn createCellListAndLineList(a: Allocator, source: []const u8) !struct { List(Cell), List(Line) } {
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

fn isSpace(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
        ' ' => true,
        '\t' => true,
        else => false,
    };
}

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

fn moveCursorForwardLikeVim(source: []const u8, cells: []const Cell, lines: []const Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
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

test moveCursorForwardLikeVim {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const source = "";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 100, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 12));
    }

    {
        const source = "hello world";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 100, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 12));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
    }

    {
        const source =
            \\hello
            \\world wide web
        ;
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 1, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 1, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 0));
        try eq(.{ 1, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 6));
    }

    {
        const source = "a b c d eee ffff";
        const cells, const lines = try createCellListAndLineList(a, source);

        try eq(.{ 0, 2 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 4 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 2));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 4));
        try eq(.{ 0, 8 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 8));

        try eq(.{ 0, 2 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 1));
        try eq(.{ 0, 4 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 3));
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 5));
        try eq(.{ 0, 8 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 7));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 9));
    }

    {
        const source = "hello  world";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 7 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 12 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 7));
    }

    {
        const source = "const four = 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 13 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four     = 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 17 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 15));
    }

    {
        const source = "const four == 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 14 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four === 4";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
    }

    {
        const source = "const four === #four";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 16));
    }

    {
        const source = "const four === #four;";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 16));
    }

    {
        const source = "const four === #four;a bbb\nvar something\nvar;";
        const cells, const lines = try createCellListAndLineList(a, source);
        try eq(.{ 0, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 6));
        try eq(.{ 0, 15 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 11));
        try eq(.{ 0, 16 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 15));
        try eq(.{ 0, 20 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 16));
        try eq(.{ 0, 21 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 20));
        try eq(.{ 0, 23 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 21));
        try eq(.{ 1, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 23));
        try eq(.{ 1, 4 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 0));
        try eq(.{ 2, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 4));
        try eq(.{ 2, 3 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 2, 0));
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

// fn moveCursorBackwardsLikeVim(source: []const u8, cells: []const Cell, lines: []const Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
//     // TODO:
// }
//
// test moveCursorBackwardsLikeVim {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const a = arena.allocator();
//
//     {
//         const source = "";
//         const cells, const lines = try createCellListAndLineList(a, source);
//         try eq(.{ 0, 0 }, moveCursorBackwardsLikeVim(source, cells.items, lines.items, 0, 0));
//         try eq(.{ 0, 0 }, moveCursorBackwardsLikeVim(source, cells.items, lines.items, 100, 0));
//         try eq(.{ 0, 0 }, moveCursorBackwardsLikeVim(source, cells.items, lines.items, 0, 200));
//     }
//
//     {
//         const source = "hello world";
//         const cells, const lines = try createCellListAndLineList(a, source);
//         try eq(.{ 0, 6 }, moveCursorBackwardsLikeVim(source, cells.items, lines.items, 0, 11));
//         try eq(.{ 0, 0 }, moveCursorBackwardsLikeVim(source, cells.items, lines.items, 0, 6));
//     }
// }
