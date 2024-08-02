const std = @import("std");
const rope = @import("rope");

const _cell = @import("cell.zig");
const Cell = _cell.Cell;
const Line = _cell.Line;
const Cursor = @import("cursor.zig").Cursor;

const Allocator = std.mem.Allocator;
const List = std.ArrayList;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const UglyTextBox = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,

    root: *const rope.Node,
    document: List(u8),
    cells: List(Cell),
    lines: List(Line),

    cursor: Cursor,

    x: i32,
    y: i32,

    fn spawn(external_allocator: Allocator, content: []const u8, x: i32, y: i32) !*@This() {
        var self = try external_allocator.create(@This());
        self.external_allocator = external_allocator;
        self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.a = self.arena.allocator();

        self.root = try rope.Node.fromString(self.a, content, true);
        self.document = try self.root.getContent(self.a);
        self.cells, self.lines = try _cell.createCellListAndLineList(self.a, self.document.items);

        self.cursor = Cursor{};

        self.x = x;
        self.y = y;

        return self;
    }
    test spawn {
        const a = std.testing.allocator;
        const box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
        defer box.destroy();
        try eqStr("Hello World!", box.lines.items[0].getText(box.cells.items, box.document.items));
    }

    fn destroy(self: *UglyTextBox) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    ///////////////////////////// Basic Cursor Movement

    fn moveCursorLeft(self: *UglyTextBox, count: usize) void {
        self.cursor.left(count);
    }
    fn moveCursorRight(self: *UglyTextBox, count: usize) void {
        const current_line = self.lines.items[self.cursor.line];
        self.cursor.right(count, current_line.numOfCells());
    }
    fn moveCursorUp(self: *UglyTextBox, count: usize) void {
        self.cursor.up(count);
    }
    fn moveCursorDown(self: *UglyTextBox, count: usize) void {
        self.cursor.down(count, self.lines.items.len);
    }

    ///////////////////////////// Insert

    fn insertChars(self: *UglyTextBox, chars: []const u8) !void {
        const current_line = self.lines.items[self.cursor.line];
        const cell_at_cursor = current_line.cell(self.cells.items, self.cursor.col);
        const insert_index = if (cell_at_cursor) |cell| cell.start_byte else self.document.items.len;

        const new_root = try self.root.insertChars(self.a, insert_index, chars);
        self.root = new_root;

        self.document.deinit();
        self.document = try self.root.getContent(self.a);

        self.cells.deinit();
        self.lines.deinit();
        self.cells, self.lines = try _cell.createCellListAndLineList(self.a, self.document.items);
    }
    test insertChars {
        const a = std.testing.allocator;
        {
            var box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
            defer box.destroy();
            try box.insertChars("OK! ");
            try eqStr("OK! Hello World!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorRight(100);
            try box.insertChars(" Here I go!");
            try eqStr("OK! Hello World! Here I go!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorRight(100);
            try box.insertChars("\n");
            try eqStr("", box.lines.items[1].getText(box.cells.items, box.document.items));

            box.cursor.set(1, 0);
            try box.insertChars("...");
            try eqStr("OK! Hello World! Here I go!", box.lines.items[0].getText(box.cells.items, box.document.items));
            try eqStr("...", box.lines.items[1].getText(box.cells.items, box.document.items));
        }
    }
};

test {
    std.testing.refAllDecls(UglyTextBox);
}
