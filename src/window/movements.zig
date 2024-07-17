const std = @import("std");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Cell = struct { char: []const u8 };
pub const Line = struct {
    start: usize,
    end: usize,

    pub fn getCells(self: *@This(), cells: []const Cell) []Cell {
        return cells[self.start..self.end];
    }
};

fn createCellsForTesting(comptime chars: []const []const u8) [chars.len]Cell {
    comptime var cells = [_]Cell{undefined} ** chars.len;
    inline for (chars, 0..) |char, i| cells[i] = Cell{ .char = char };
    return cells;
}

test "example" {
    const chars = [_][]const u8{ "h", "e", "l", "l", "o" };
    const cells = createCellsForTesting(&chars);
    try eqStr("h", cells[0].char);
    try eqStr("e", cells[1].char);
}
