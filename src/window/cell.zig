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
};

fn createCellList(a: Allocator, source: []const u8) !List(Cell) {
    var list = List(Cell).init(a);
    var iter = code_point.Iterator{ .bytes = source };
    while (iter.next()) |cp|
        try list.append(Cell{ .start_byte = cp.offset, .end_byte = cp.offset + cp.len });
    return list;
}

test createCellList {
    const a = std.testing.allocator;
    const source = "안녕하세요!\nHello there 👋!";
    const cells = try createCellList(a, source);
    defer cells.deinit();
    try eqStr("안", cells.items[0].getText(source));
    try eqStr("\n", cells.items[6].getText(source));
    try eqStr("!", cells.items[cells.items.len - 1].getText(source));
    try eqStr("👋", cells.items[cells.items.len - 2].getText(source));
}
