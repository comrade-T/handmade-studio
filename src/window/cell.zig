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

    pub fn getText(self: *@This(), source: []const u8) []const u8 {
        return source[self.start_byte..self.end_byte];
    }
};

pub const Line = struct {
    start: usize,
    end: usize,

    pub fn getCells(self: *@This(), cells: []const Cell) []Cell {
        return cells[self.start..self.end];
    }

    pub fn getText(self: *@This(), cells: []const Cell, source: []const u8) []const u8 {
        const start_byte = cells[self.start].start_byte;
        const end_byte = cells[self.end].end_byte;
        return source[start_byte..end_byte];
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
            try lines.append(Line{ .start = i, .end = cells.items.len - 2 });
            i += cells.items.len;
        }
    }
    try lines.append(Line{ .start = i, .end = cells.items.len - 1 });

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
