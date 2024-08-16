const std = @import("std");
const Buffer = @import("neo_buffer").Buffer;
const ContentVendor = @import("content_vendor").ContentVendor;
const testIter = ContentVendor.CurrentJobIterator.testIter;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    pub fn set(self: *Cursor, line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }
};

pub const Window = struct {
    a: Allocator,
    vendor: *ContentVendor,

    // TODO: let's work on single cursor first,
    // then we can move on to multiple cursors after that.
    // either it's simultanious or individual separate cursors.
    // cursors: ArrayList(Cursor),

    cursor: Cursor,

    x: f32,
    y: f32,

    pub fn spawn(a: Allocator, vendor: *ContentVendor, x: f32, y: f32) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .cursor = Cursor{},
            .vendor = vendor,

            .x = x,
            .y = y,
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        // self.cursors.deinit();
        self.a.destroy(self);
    }

    pub fn insertChars(self: *@This(), chars: []const u8) void {
        self.insertCharsInternal(chars) catch @panic("error calling Window.insertCharsInternal()");
    }

    pub fn doCustomStuffs(self: *@This(), trigger: []const u8) !void {
        if (eql(u8, trigger, "up")) try self.moveCursorUp();
        if (eql(u8, trigger, "down")) try self.moveCursorDown();
        if (eql(u8, trigger, "left")) self.moveCursorLeft();
        if (eql(u8, trigger, "right")) try self.moveCursorRight();
        if (eql(u8, trigger, "backspace")) try self.backspace();
    }

    ///////////////////////////// Cursor Movement

    fn moveCursorUp(self: *@This()) !void {
        if (self.cursor.line == 0) return;
        const new_line_noc = try self.vendor.buffer.roperoot.getNumOfCharsOfLine(self.cursor.line - 1);
        const new_col = if (self.cursor.col > new_line_noc) new_line_noc else self.cursor.col;
        self.cursor.set(self.cursor.line - 1, new_col);
    }

    fn moveCursorDown(self: *@This()) !void {
        const new_line = self.cursor.line + 1;
        if (new_line >= self.vendor.buffer.roperoot.weights().bols) return;
        const new_line_noc = try self.vendor.buffer.roperoot.getNumOfCharsOfLine(new_line);
        const new_col = if (self.cursor.col > new_line_noc) new_line_noc else self.cursor.col;
        self.cursor.set(new_line, new_col);
    }

    fn moveCursorLeft(self: *@This()) void {
        self.cursor.col = self.cursor.col -| 1;
    }

    fn moveCursorRight(self: *@This()) !void {
        const cur_line_noc = try self.vendor.buffer.roperoot.getNumOfCharsOfLine(self.cursor.line);
        const target = self.cursor.col + 1;
        self.cursor.col = if (self.cursor.col + 1 < cur_line_noc) target else cur_line_noc;
    }
    test moveCursorRight {
        { // single line
            const win = try setupZigWindow("const");
            defer teardownWindow(win);
            try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 1 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 2 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 3 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 4 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 5 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 5 }); // stays at 5
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 5 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 5 });
        }
        { // multi line
            const win = try setupZigWindow("one\n22");
            defer teardownWindow(win);
            try eq(Cursor{ .line = 0, .col = 0 }, win.cursor);
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 1 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 2 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 3 });
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 3 }); // stays at 3
            try testMoveCursorRight(win, Cursor{ .line = 0, .col = 3 });

            win.cursor.set(1, 0);
            try eq(Cursor{ .line = 1, .col = 0 }, win.cursor);
            try testMoveCursorRight(win, Cursor{ .line = 1, .col = 1 });
            try testMoveCursorRight(win, Cursor{ .line = 1, .col = 2 });
            try testMoveCursorRight(win, Cursor{ .line = 1, .col = 2 }); // stays at 2
            try testMoveCursorRight(win, Cursor{ .line = 1, .col = 2 });
            try testMoveCursorRight(win, Cursor{ .line = 1, .col = 2 });
        }
    }
    fn testMoveCursorRight(win: *Window, expected_cursor: Cursor) !void {
        try win.moveCursorRight();
        try eq(expected_cursor, win.cursor);
    }

    ///////////////////////////// Delete

    fn backspace(self: *@This()) !void {
        if (self.cursor.line == 0 and self.cursor.col == 0) return;

        if (self.cursor.col == 0) {
            const new_line = self.cursor.line - 1;
            const new_col = try self.vendor.buffer.roperoot.getNumOfCharsOfLine(new_line);
            try self.vendor.buffer.deleteRange(
                .{ new_line, new_col },
                .{ self.cursor.line, self.cursor.col },
            );
            self.cursor.set(new_line, new_col);
            return;
        }

        self.moveCursorLeft();
        try self.vendor.buffer.deleteRange(
            .{ self.cursor.line, self.cursor.col },
            .{ self.cursor.line, self.cursor.col + 1 },
        );
    }
    test backspace {
        {
            { // single line case
                const win = try setupZigWindow("");
                defer teardownWindow(win);

                win._insertOneCharAfterAnother("var");
                try testFirstIter(win, "var", "type.qualifier");

                try win.backspace();
                try testFirstIter(win, "va", "variable");

                try win.backspace();
                try testFirstIter(win, "v", "variable");

                try win.backspace();
                try testFirstIter(win, null, "variable");

                try win.backspace();
                try testFirstIter(win, null, "variable");
            }
            { // 2 lines cases
                const win = try setupZigWindow("");
                defer teardownWindow(win);
                {
                    win._insertOneCharAfterAnother("var\nconst");
                    try eq(Cursor{ .line = 1, .col = 5 }, win.cursor);
                    const iter = try win.vendor.requestLines(0, 9999);
                    defer iter.deinit();
                    try testIter(iter, "var", "type.qualifier");
                    try testIter(iter, "\nconst", "variable");
                    try testIter(iter, null, null);
                }
                {
                    try win.backspace();
                    const iter = try win.vendor.requestLines(0, 9999);
                    defer iter.deinit();
                    try testIter(iter, "var", "type.qualifier");
                    try testIter(iter, "\ncons", "variable");
                    try testIter(iter, null, null);
                }
                {
                    try win.backspace();
                    try win.backspace();
                    try win.backspace();
                    const iter = try win.vendor.requestLines(0, 9999);
                    defer iter.deinit();
                    try testIter(iter, "var", "type.qualifier");
                    try testIter(iter, "\nc", "variable");
                    try testIter(iter, null, null);
                }
                {
                    try eq(Cursor{ .line = 1, .col = 1 }, win.cursor);
                    try win.backspace();
                    const iter = try win.vendor.requestLines(0, 9999);
                    defer iter.deinit();
                    try testIter(iter, "var", "type.qualifier");
                    try testIter(iter, "\n", "variable");
                    try testIter(iter, null, null);
                }
                {
                    try eq(Cursor{ .line = 1, .col = 0 }, win.cursor);
                    try win.backspace();
                    const iter = try win.vendor.requestLines(0, 9999);
                    defer iter.deinit();
                    try testIter(iter, "var", "type.qualifier");
                    try testIter(iter, null, null);
                }
                {
                    try win.backspace();
                    try testFirstIter(win, "va", "variable");
                    try win.backspace();
                    try testFirstIter(win, "v", "variable");
                    try win.backspace();
                    try testFirstIter(win, null, "variable");
                }
            }
        }
    }
    ///////////////////////////// Insert

    fn insertCharsInternal(self: *@This(), chars: []const u8) !void {
        const new_line, const new_col = try self.vendor.buffer.insertChars(chars, self.cursor.line, self.cursor.col);
        self.cursor.set(new_line, new_col);
    }
    test insertCharsInternal {
        {
            const win = try setupZigWindow("");
            defer teardownWindow(win);
            {
                win.insertChars("c");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "c", "variable");
            }
            {
                win.insertChars("o");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "co", "variable");
            }
            {
                win.insertChars("n");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "con", "variable");
            }
            {
                win.insertChars("s");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "cons", "variable");
            }
            {
                win.insertChars("t");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "const", "type.qualifier");
            }
        }
        {
            const win = try setupZigWindow("");
            defer teardownWindow(win);
            {
                win._insertOneCharAfterAnother("const");
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, null, null);
            }
            {
                win.insertChars("\n");
                try eq(Cursor{ .line = 1, .col = 0 }, win.cursor);
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, null, null);
            }
            {
                win.insertChars("\n");
                try eq(Cursor{ .line = 2, .col = 0 }, win.cursor);
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "\n", "variable");
                try testIter(iter, null, null);
            }
            {
                win.insertChars("v");
                try eq(Cursor{ .line = 2, .col = 1 }, win.cursor);
                const iter = try win.vendor.requestLines(0, 9999);
                defer iter.deinit();
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "v", "variable");
                try testIter(iter, null, null);
            }
        }
    }

    ///////////////////////////// Test Helpers

    fn _insertOneCharAfterAnother(win: *Window, chars: []const u8) void {
        for (0..chars.len) |i| win.insertChars(chars[i .. i + 1]);
    }

    fn testFirstIter(win: *Window, expected_str: ?[]const u8, expected_hlgroup: []const u8) !void {
        const iter = try win.vendor.requestLines(0, 9999);
        defer iter.deinit();
        try testIter(iter, expected_str, expected_hlgroup);
    }

    fn setupZigWindow(source: []const u8) !*@This() {
        var buf = try Buffer.create(testing_allocator, .string, source);
        try buf.initiateTreeSitter(.zig);
        const vendor = try ContentVendor.init(testing_allocator, buf);
        const win = try Window.spawn(testing_allocator, vendor, 100, 100);
        return win;
    }

    fn teardownWindow(win: *Window) void {
        win.vendor.buffer.destroy();
        win.vendor.deinit();
        win.destroy();
    }
};

test {
    std.testing.refAllDeclsRecursive(Window);
}
