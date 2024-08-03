const std = @import("std");
const rope = @import("rope");

const _cell = @import("cell.zig");
const Cell = _cell.Cell;
const Line = _cell.Line;
const WordBoundaryType = _cell.WordBoundaryType;
const Cursor = @import("cursor.zig").Cursor;

const Allocator = std.mem.Allocator;
const List = std.ArrayList;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const UglyTextBox = struct {
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

    pub fn spawn(external_allocator: Allocator, content: []const u8, x: i32, y: i32) !*@This() {
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
    pub fn destroy(self: *UglyTextBox) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    ///////////////////////////// Get Document

    pub fn getDocument(self: *UglyTextBox) [*:0]const u8 {
        if (self.document.items.len > 0) return @ptrCast(self.document.items);
        return "";
    }

    ///////////////////////////// Basic Cursor Movement

    pub fn moveCursorLeft(self: *UglyTextBox, count: usize) void {
        self.cursor.left(count);
    }
    pub fn moveCursorRight(self: *UglyTextBox, count: usize) void {
        const current_line = self.lines.items[self.cursor.line];
        self.cursor.right(count, current_line.numOfCells());
    }
    pub fn moveCursorUp(self: *UglyTextBox, count: usize) void {
        self.cursor.up(count);
    }
    pub fn moveCursorDown(self: *UglyTextBox, count: usize) void {
        self.cursor.down(count, self.lines.items.len);
    }

    ///////////////////////////// Move by word

    pub fn moveCursorBackwardsByWord(self: *UglyTextBox, destination: WordBoundaryType) void {
        const new_line, const new_col = _cell.backwardsByWord(destination, self.document.items, self.cells.items, self.lines.items, self.cursor.line, self.cursor.col);
        self.cursor.set(new_line, new_col);
    }
    pub fn moveCursorForwardByWord(self: *UglyTextBox, destination: WordBoundaryType) void {
        const new_line, const new_col = _cell.forwardByWord(destination, self.document.items, self.cells.items, self.lines.items, self.cursor.line, self.cursor.col);
        self.cursor.set(new_line, new_col);
    }
    test "move cursor forward / backward by word" {
        const a = std.testing.allocator;
        {
            var box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
            defer box.destroy();

            box.moveCursorForwardByWord(.start);
            try box.insertChars("my ");
            try eqStr("Hello my World!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorForwardByWord(.end);
            box.moveCursorRight(1);
            try box.insertChars("ne");
            try eqStr("Hello myne World!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorBackwardsByWord(.start);
            try box.insertChars("_");
            try eqStr("Hello _myne World!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorBackwardsByWord(.end);
            box.moveCursorRight(1);
            try box.insertChars("!");
            try eqStr("Hello! _myne World!", box.lines.items[0].getText(box.cells.items, box.document.items));

            box.moveCursorBackwardsByWord(.start);
            try box.insertChars("~");
            try eqStr("~Hello! _myne World!", box.lines.items[0].getText(box.cells.items, box.document.items));
        }
    }

    ///////////////////////////// Insert

    pub fn insertChars(self: *UglyTextBox, chars: []const u8) !void {
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

    ///////////////////////////// Delete

    pub fn backspace(self: *UglyTextBox) !void {
        if (self.cursor.line == 0 and self.cursor.col == 0) return;

        var start_byte: usize = 0;
        var byte_count: usize = 0;

        if (self.cursor.col == 0) {
            const prev_line = self.lines.items[self.cursor.line - 1];
            const prev_line_last_cell = prev_line.cell(self.cells.items, prev_line.numOfCells()).?;
            start_byte = prev_line_last_cell.end_byte - 1;
            byte_count = 1;
        } else {
            const line = self.lines.items[self.cursor.line];
            const cell = line.cell(self.cells.items, self.cursor.col - 1).?;
            start_byte = cell.start_byte;
            byte_count = cell.len();
        }

        const new_root = try self.root.deleteBytes(self.a, start_byte, byte_count);
        self.root = new_root;

        self.document.deinit();
        self.document = try self.root.getContent(self.a);

        self.cells.deinit();
        self.lines.deinit();
        self.cells, self.lines = try _cell.createCellListAndLineList(self.a, self.document.items);
    }
    test backspace {
        const a = std.testing.allocator;
        { // backspace at end of line
            var box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
            defer box.destroy();
            box.moveCursorRight(100);
            try box.backspace();
            try eqStr("Hello World", box.lines.items[0].getText(box.cells.items, box.document.items));
        }
        { // backspace in middle of line
            var box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
            defer box.destroy();
            box.moveCursorRight(100);
            box.moveCursorLeft(1);
            try box.backspace();
            try eqStr("Hello Worl!", box.lines.items[0].getText(box.cells.items, box.document.items));
        }
        { // backspace at start of document, should do nothing
            var box = try UglyTextBox.spawn(a, "Hello World!", 0, 0);
            defer box.destroy();
            try box.backspace();
            try eqStr("Hello World!", box.lines.items[0].getText(box.cells.items, box.document.items));
        }
        { // backspace at start of line that's not the first line of document
            var box = try UglyTextBox.spawn(a, "Hello\nWorld!", 0, 0);
            defer box.destroy();
            try eqStr("Hello", box.lines.items[0].getText(box.cells.items, box.document.items));
            try eqStr("World!", box.lines.items[1].getText(box.cells.items, box.document.items));

            box.cursor.set(1, 0);
            try box.backspace();
            try eq(1, box.lines.items.len);
        }
    }
};

test {
    std.testing.refAllDecls(UglyTextBox);
}
