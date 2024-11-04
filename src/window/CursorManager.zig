const CursorManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const code_point = @import("code_point");
const RopeMan = @import("RopeMan");

//////////////////////////////////////////////////////////////////////////////////////////////

cursors: ArrayList(Cursor),

const GetNumOfLinesCallback = *const fn (ctx: *anyopaque) usize;
const GetNocInLineCallback = *const fn (ctx: *anyopaque, linenr: usize) usize;
const GetLineCallback = *const fn (ctx: *anyopaque, a: Allocator, linenr: usize) []const u8;

const Cursor = struct {
    line: usize,
    col: usize,

    ///////////////////////////// hjkl

    pub fn moveUp(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line -|= by;
        self.restrictCol(ropeman);
    }

    pub fn moveDown(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.line += by;
        const nol = ropeman.getNumOfLines();
        if (self.line >= nol) self.line = nol -| 1;
        self.restrictCol(ropeman);
    }

    pub fn moveLeft(self: *@This(), by: usize) void {
        self.col -|= by;
    }

    pub fn moveRight(self: *@This(), by: usize, ropeman: *const RopeMan) void {
        self.col += by;
        self.restrictCol(ropeman);
    }

    pub fn restrictCol(self: *@This(), ropeman: *const RopeMan) void {
        const noc = ropeman.getNumOfCharsInLine(self.line);
        if (self.col > noc) self.col = noc;
    }

    ///////////////////////////// w/W

    pub fn forwardWord(self: *@This(), a: Allocator, count: usize, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        for (0..count) |_| self.forwardWordSingleTime(a, start_or_end, boundary_kind, ropeman);
    }

    fn forwardWordSingleTime(self: *@This(), a: Allocator, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, ropeman: *const RopeMan) void {
        var start_char_kind = CharKind.not_found;
        var passed_a_space = false;

        const num_of_lines = ropeman.getNumOfLines();
        for (self.line..num_of_lines) |linenr| {
            const line = ropeman.getLineAlloc(a, linenr, 1024) catch return;
            defer a.free(line);

            self.line = linenr;
            switch (findForwardTargetInLine(self.col, line, start_or_end, boundary_kind, &start_char_kind, &passed_a_space)) {
                .not_found => self.col = if (self.line + 1 >= num_of_lines) line.len else 0,
                .found => |colnr| {
                    self.col = colnr;
                    return;
                },
            }
        }
    }

    const StartOrEnd = enum { start, end };
    const BoundaryKind = enum { word, BIG_WORD };
    const FindForwardTargetInLineResult = union(enum) { not_found, found: usize };
    fn findForwardTargetInLine(cursor_col: usize, line: []const u8, start_or_end: StartOrEnd, boundary_kind: BoundaryKind, start_char_kind: *CharKind, passed_a_space: *bool) FindForwardTargetInLineResult {
        if (start_char_kind.* != .not_found) passed_a_space.* = true;
        if (line.len == 0) return .not_found;

        var iter = code_point.Iterator{ .bytes = line };
        var i: usize = 0;
        while (iter.next()) |cp| {
            defer i += 1;
            const char_type = getCharKind(u21, cp.code);

            if (start_char_kind.* == .not_found) {
                if (i == cursor_col) start_char_kind.* = char_type;
                continue;
            }

            switch (start_or_end) {
                .start => {
                    switch (char_type) {
                        .not_found => unreachable,
                        .spacing => passed_a_space.* = true,
                        .char => if (passed_a_space.* or (boundary_kind == .word and start_char_kind.* == .symbol)) return .{ .found = i },
                        .symbol => if (passed_a_space.* or (boundary_kind == .word and start_char_kind.* == .char)) return .{ .found = i },
                    }
                },
                .end => {
                    if (char_type == .spacing) continue;
                    const peek_result = iter.peek() orelse return .{ .found = i };
                    const peek_char_type = getCharKind(u21, peek_result.code);
                    switch (peek_char_type) {
                        .not_found => unreachable,
                        .spacing => return .{ .found = i },
                        else => if (boundary_kind == .word and char_type != peek_char_type) return .{ .found = i },
                    }
                },
            }
        }

        return .not_found;
    }
};

test "Cursor - basic hjkl movements" {
    var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hi\nworld\nhello\nx");
    defer ropeman.deinit();
    var c = Cursor{ .line = 0, .col = 0 };

    // moveRight()
    {
        c.moveRight(1, &ropeman);
        try eq(Cursor{ .line = 0, .col = 1 }, c);

        c.moveRight(2, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);
    }

    // moveLeft()
    {
        c.moveLeft(1);
        try eq(Cursor{ .line = 0, .col = 1 }, c);
        c.moveLeft(100);
        try eq(Cursor{ .line = 0, .col = 0 }, c);
    }

    // moveDown()
    {
        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);

        c.moveDown(1, &ropeman);
        try eq(Cursor{ .line = 1, .col = 2 }, c);

        c.moveDown(1, &ropeman);
        try eq(Cursor{ .line = 2, .col = 2 }, c);

        c.moveDown(100, &ropeman);
        try eq(Cursor{ .line = 3, .col = 1 }, c);
    }

    // moveUp()
    {
        c.moveUp(1, &ropeman);
        try eq(Cursor{ .line = 2, .col = 1 }, c);

        c.moveRight(100, &ropeman);
        try eq(Cursor{ .line = 2, .col = 5 }, c);

        c.moveUp(100, &ropeman);
        try eq(Cursor{ .line = 0, .col = 2 }, c);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Vim Movements

test "Cursor - forwardWord()" {
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 6 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 3 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);
        }
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 2, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 2, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);

            c.forwardWord(testing_allocator, 100, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);
        }
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 100, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello; world;\nhi venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 5 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 7 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 12 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 3 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);
        }
        { // .BIG_WORD
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 0, .col = 7 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 3 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 8 }, c);
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;  world;\nhi   venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 5 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 8 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 13 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 5 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 10 }, c);
        }
        { // .BIG_WORD
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 0, .col = 8 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 0 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 5 }, c);

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 10 }, c);
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "one;two--3|||four;");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 3 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 7 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 9 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 10 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 13 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 17 }, c);

            c.forwardWord(testing_allocator, 1, .start, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 18 }, c);
        }
        { // .BIG_WORD
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .start, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 0, .col = 18 }, c);
        }
    }

    ///////////////////////////// .end

    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello world\nhi venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 10 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 1 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 7 }, c);
        }
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 2, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 10 }, c);

            c.forwardWord(testing_allocator, 2, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 7 }, c);
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;; world;\nhi;;; venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 6 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 12 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 13 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 1 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 10 }, c);
        }
    }
    {
        var ropeman = try RopeMan.initFrom(testing_allocator, .string, "hello;;  world;\nhi;;;   venus");
        defer ropeman.deinit();
        {
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 6 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 13 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 0, .col = 14 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 1 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .word, &ropeman);
            try eq(Cursor{ .line = 1, .col = 12 }, c);
        }
        { // .BIG_WORD
            var c = Cursor{ .line = 0, .col = 0 };

            c.forwardWord(testing_allocator, 1, .end, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 0, .col = 6 }, c);

            c.forwardWord(testing_allocator, 1, .end, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 0, .col = 14 }, c);

            c.forwardWord(testing_allocator, 1, .end, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 4 }, c);

            c.forwardWord(testing_allocator, 1, .end, .BIG_WORD, &ropeman);
            try eq(Cursor{ .line = 1, .col = 12 }, c);
        }
    }
}

const CharKind = enum { spacing, symbol, char, not_found };

fn getCharKind(T: type, b: T) CharKind {
    return switch (b) {
        ' ' => .spacing,
        '\t' => .spacing,
        '\n' => .spacing,

        '=' => .symbol,
        '"' => .symbol,
        '\'' => .symbol,
        '/' => .symbol,
        '\\' => .symbol,
        '*' => .symbol,
        ':' => .symbol,
        '.' => .symbol,
        ',' => .symbol,
        '(' => .symbol,
        ')' => .symbol,
        '{' => .symbol,
        '}' => .symbol,
        '[' => .symbol,
        ']' => .symbol,
        ';' => .symbol,
        '|' => .symbol,
        '?' => .symbol,
        '&' => .symbol,
        '#' => .symbol,
        '-' => .symbol,

        else => .char,
    };
}
