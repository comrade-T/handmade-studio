const std = @import("std");

const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    pub fn up(self: *Cursor, by: usize) void {
        self.line = self.line -| by;
    }

    pub fn down(self: *Cursor, by: usize, buffer_height: usize) void {
        const target = self.line + by;
        self.line = if (self.line + by < buffer_height - 1) target else buffer_height - 1;
    }

    pub fn right(self: *Cursor, by: usize, line_width: usize) void {
        const target = self.col + by;
        self.col = if (self.col + by < line_width - 1) target else line_width - 1;
    }

    pub fn left(self: *Cursor, by: usize) void {
        self.col = self.col -| by;
    }
};

test Cursor {
    var c = Cursor{};
    try eqDeep(Cursor{ .line = 0, .col = 0 }, c);

    {
        const buffer_height = 10;

        c.down(1, buffer_height);
        try eqDeep(Cursor{ .line = 1, .col = 0 }, c);

        c.down(100, buffer_height);
        try eqDeep(Cursor{ .line = 9, .col = 0 }, c);
    }

    {
        c.up(1);
        try eqDeep(Cursor{ .line = 8, .col = 0 }, c);

        c.up(3);
        try eqDeep(Cursor{ .line = 5, .col = 0 }, c);
    }

    {
        const line_5_width = 10;

        c.right(1, line_5_width);
        try eqDeep(Cursor{ .line = 5, .col = 1 }, c);

        c.right(100, line_5_width);
        try eqDeep(Cursor{ .line = 5, .col = 9 }, c);
    }

    {
        c.left(1);
        try eqDeep(Cursor{ .line = 5, .col = 8 }, c);

        c.left(100);
        try eqDeep(Cursor{ .line = 5, .col = 0 }, c);
    }
}
