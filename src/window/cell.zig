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
        else => false,
    };
}

fn moveCursorForwardLikeVim(source: []const u8, cells: []const Cell, lines: []const Line, linenr: usize, colnr: usize) struct { usize, usize } {
    const last_line_index = lines.len - 1;
    const last_line = lines[last_line_index];
    const last_line_cells = last_line.getCells(cells);

    const default_target_linenr = lines.len - 1;
    const default_target_colnr = last_line_cells.len;

    if (linenr > last_line_index) return .{ default_target_linenr, default_target_colnr };
    if (linenr == last_line_index and colnr >= last_line_cells.len) return .{ default_target_linenr, default_target_colnr };

    var target_linenr = linenr;
    var target_colnr = colnr;
    const start = lines[linenr].start + colnr;
    for (cells[start..cells.len], start..) |cell, i| {
        if (i < cells.len - 1 and lines[target_linenr].end - 1 == i) {
            target_linenr += 1;
            target_colnr = 0;
            return .{ target_linenr, target_colnr };
        }
        target_colnr += 1;
        if (isNotWordChar(cell.getText(source))) return .{ target_linenr, target_colnr };
    }

    return .{ default_target_linenr, default_target_colnr };
}

test moveCursorForwardLikeVim {
    const a = std.testing.allocator;

    {
        const source = "";
        const cells, const lines = try createCellListAndLineList(a, source);
        defer cells.deinit();
        defer lines.deinit();

        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 100, 0));
        try eq(.{ 0, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 12));
    }

    {
        const source = "hello world";
        const cells, const lines = try createCellListAndLineList(a, source);
        defer cells.deinit();
        defer lines.deinit();

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
        defer cells.deinit();
        defer lines.deinit();

        try eq(.{ 1, 0 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 0, 0));
        try eq(.{ 1, 6 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 0));
        try eq(.{ 1, 11 }, moveCursorForwardLikeVim(source, cells.items, lines.items, 1, 6));
    }
}
