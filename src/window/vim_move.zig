const std = @import("std");
const code_point = @import("code_point");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

const GetLineCallback = *const fn (a: Allocator, ctx: *anyopaque, linenr: usize) []const u21;

pub fn forwardByWord(
    a: Allocator,
    destination: WordBoundaryType,
    ctx: *anyopaque,
    cb: GetLineCallback,
    last_linenr: usize,
    last_colnr_of_last_line: usize,
    input_linenr: usize,
    input_colnr: usize,
) struct { usize, usize } {
    var linenr = input_linenr;
    var colnr = input_colnr + 1;
    if (linenr >= last_linenr and colnr >= last_colnr_of_last_line) return .{ last_linenr, last_colnr_of_last_line };

    while (true) {
        var line = cb(a, ctx, linenr);
        defer a.free(line);

        defer colnr += 1;
        if (colnr >= line.len) {
            if (linenr == last_linenr) return .{ linenr, line.len -| 1 };

            linenr += 1;
            a.free(line);
            line = cb(a, ctx, linenr);
            colnr = 0;
        }

        if (foundTargetBoundary(line, colnr, destination)) return .{ linenr, colnr };
    }
}

test forwardByWord {
    // .end
    {
        var mock = try Mockery.init(testing_allocator, "hello world");
        //                                                              4     0
        defer mock.deinit();
        try testForwardByWord(.{ 0, 4 }, .end, &mock, 0, 0, 3);
        try testForwardByWord(.{ 0, 10 }, .end, &mock, 0, 4, 10);
        try testForwardByWord(.{ 0, 10 }, .end, &mock, 0, 11, 100); // out of bounds
    }
    {
        var mock = try Mockery.init(testing_allocator, "one#two--3|||four;;;;");
        //                                                            23  6 89  2   6   0
        defer mock.deinit();
        try testForwardByWord(.{ 0, 2 }, .end, &mock, 0, 0, 1);
        try testForwardByWord(.{ 0, 3 }, .end, &mock, 0, 2, 2);
        try testForwardByWord(.{ 0, 6 }, .end, &mock, 0, 3, 5);
        try testForwardByWord(.{ 0, 8 }, .end, &mock, 0, 6, 7);
        try testForwardByWord(.{ 0, 9 }, .end, &mock, 0, 8, 8);
        try testForwardByWord(.{ 0, 12 }, .end, &mock, 0, 9, 11);
        try testForwardByWord(.{ 0, 16 }, .end, &mock, 0, 12, 15);
        try testForwardByWord(.{ 0, 20 }, .end, &mock, 0, 16, 19);
    }
    {
        var mock = try Mockery.init(testing_allocator, "draw forth\nmy map");
        //                                                             3     9   1   5
        defer mock.deinit();
        try testForwardByWord(.{ 0, 3 }, .end, &mock, 0, 0, 2);
        try testForwardByWord(.{ 0, 9 }, .end, &mock, 0, 3, 8);
        try testForwardByWord(.{ 1, 1 }, .end, &mock, 0, 9, 9);
        try testForwardByWord(.{ 1, 1 }, .end, &mock, 1, 0, 0);
        try testForwardByWord(.{ 1, 5 }, .end, &mock, 1, 1, 4);
        try testForwardByWord(.{ 1, 5 }, .end, &mock, 1, 5, 100); // out of bounds
    }
    // start
    {
        {
            var mock = try Mockery.init(testing_allocator, "hello world");
            //                                                                6   0
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 0, 10 }, .start, &mock, 0, 6, 9);
            try testForwardByWord(.{ 0, 10 }, .start, &mock, 0, 10, 100); // out of bounds
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello; world");
            //                                                               5 7   1
            defer mock.deinit();
            try testForwardByWord(.{ 0, 5 }, .start, &mock, 0, 0, 4);
            try testForwardByWord(.{ 0, 7 }, .start, &mock, 0, 5, 6);
            try testForwardByWord(.{ 0, 11 }, .start, &mock, 0, 7, 11);
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello ; world");
            //                                                                6 8   2
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 0, 8 }, .start, &mock, 0, 6, 7);
            try testForwardByWord(.{ 0, 12 }, .start, &mock, 0, 8, 12);
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello ;; world");
            //                                                                6  9   3
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 0, 9 }, .start, &mock, 0, 6, 8);
            try testForwardByWord(.{ 0, 13 }, .start, &mock, 0, 9, 13);
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello  world one  two");
            //                                                                 7     3    8 0
            defer mock.deinit();
            try testForwardByWord(.{ 0, 7 }, .start, &mock, 0, 0, 6);
            try testForwardByWord(.{ 0, 13 }, .start, &mock, 0, 7, 12);
            try testForwardByWord(.{ 0, 18 }, .start, &mock, 0, 13, 17);
            try testForwardByWord(.{ 0, 20 }, .start, &mock, 0, 18, 20);
        }
        {
            var mock = try Mockery.init(testing_allocator, "one|two||3|||four");
            //                                                             34  7 90  3  6
            defer mock.deinit();
            try testForwardByWord(.{ 0, 3 }, .start, &mock, 0, 0, 2);
            try testForwardByWord(.{ 0, 4 }, .start, &mock, 0, 3, 3);
            try testForwardByWord(.{ 0, 7 }, .start, &mock, 0, 4, 6);
            try testForwardByWord(.{ 0, 9 }, .start, &mock, 0, 7, 8);
            try testForwardByWord(.{ 0, 10 }, .start, &mock, 0, 9, 9);
            try testForwardByWord(.{ 0, 13 }, .start, &mock, 0, 10, 12);
            try testForwardByWord(.{ 0, 16 }, .start, &mock, 0, 13, 16);
        }
        {
            var mock = try Mockery.init(testing_allocator, "const std = @import(\"std\");\nconst");
            //                                                          0     6   0 2      9  1   4    0   4
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 0, 10 }, .start, &mock, 0, 6, 9);
            try testForwardByWord(.{ 0, 12 }, .start, &mock, 0, 10, 11);
            try testForwardByWord(.{ 0, 19 }, .start, &mock, 0, 12, 18);
            try testForwardByWord(.{ 0, 21 }, .start, &mock, 0, 19, 20);
            try testForwardByWord(.{ 0, 24 }, .start, &mock, 0, 21, 23);
            try testForwardByWord(.{ 1, 0 }, .start, &mock, 0, 24, 26);
            try testForwardByWord(.{ 1, 0 }, .start, &mock, 0, 27, 100); // out of bounds on line 0
            try testForwardByWord(.{ 1, 4 }, .start, &mock, 1, 0, 3);
            try testForwardByWord(.{ 1, 4 }, .start, &mock, 1, 4, 100); // out of bounds on line 1
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello\nworld\nvenus\nmars");
            //                                                          0      0      0      0  3
            defer mock.deinit();
            try testForwardByWord(.{ 1, 0 }, .start, &mock, 0, 0, 4);
            try testForwardByWord(.{ 2, 0 }, .start, &mock, 1, 0, 4);
            try testForwardByWord(.{ 3, 0 }, .start, &mock, 2, 0, 4);
            try testForwardByWord(.{ 3, 3 }, .start, &mock, 3, 0, 2);
            try testForwardByWord(.{ 3, 3 }, .start, &mock, 3, 3, 100); // out of bouds on line 3
        }
        {
            var mock = try Mockery.init(testing_allocator, "hello world\nvenus and mars");
            //                                                          0     6      0     6   0  3
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 1, 0 }, .start, &mock, 0, 6, 10);
            try testForwardByWord(.{ 1, 6 }, .start, &mock, 1, 0, 5);
            try testForwardByWord(.{ 1, 10 }, .start, &mock, 1, 6, 9);
            try testForwardByWord(.{ 1, 13 }, .start, &mock, 1, 10, 13);
        }
        { // empty line check
            var mock = try Mockery.init(testing_allocator, "hello world\n\nand mars");
            //                                                          0     6      0 0   4  7
            defer mock.deinit();
            try testForwardByWord(.{ 0, 6 }, .start, &mock, 0, 0, 5);
            try testForwardByWord(.{ 1, 0 }, .start, &mock, 0, 6, 10);
            try testForwardByWord(.{ 2, 0 }, .start, &mock, 1, 0, 0);
            try testForwardByWord(.{ 2, 4 }, .start, &mock, 2, 0, 3);
            try testForwardByWord(.{ 2, 7 }, .start, &mock, 2, 4, 7);
        }
    }
}

fn testForwardByWord(expected: struct { usize, usize }, boundary_type: WordBoundaryType, mock: *Mockery, linenr: usize, start_col: usize, end_col: usize) !void {
    for (start_col..end_col + 1) |colnr| {
        const result = forwardByWord(
            testing_allocator,
            boundary_type,
            mock,
            Mockery.getLine,
            mock.lines.len - 1,
            mock.lines[mock.lines.len - 1].len - 1,
            linenr,
            colnr,
        );
        try eq(expected, result);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn backwardsByWord(a: Allocator, destination: WordBoundaryType, ctx: *anyopaque, cb: GetLineCallback, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    var linenr = input_linenr;
    var colnr = input_colnr -| 1;

    while (true) {
        var line = cb(a, ctx, linenr);
        defer a.free(line);

        defer colnr -|= 1;
        if (colnr == 0) {
            if (linenr == 0) return .{ 0, 0 };
            if (input_colnr > 0 and foundTargetBoundary(line, colnr, destination)) return .{ linenr, colnr };

            linenr -= 1;
            a.free(line);
            line = cb(a, ctx, linenr);
            colnr = line.len -| 1;
        }

        if (foundTargetBoundary(line, colnr, destination)) return .{ linenr, colnr };
    }

    return .{ linenr, colnr };
}

const Mockery = struct {
    a: Allocator,
    lines: []Line,

    fn init(a: Allocator, source: []const u8) !Mockery {
        return Mockery{ .a = a, .lines = try createLinesFromSource(a, source) };
    }

    fn deinit(self: *@This()) void {
        for (self.lines) |line| self.a.free(line);
        self.a.free(self.lines);
    }

    fn getLine(a: Allocator, ctx: *anyopaque, linenr: usize) []const u21 {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        return a.dupe(u21, self.lines[linenr]) catch &.{};
    }
};

test backwardsByWord {
    // .start
    {
        var mock = try Mockery.init(testing_allocator, "one;two--3|||four;");
        //                                              0  34  7 90  3   7
        defer mock.deinit();
        try testBackwardsByWord(.{ 0, 13 }, .start, &mock, 0, 14, 17);
        try testBackwardsByWord(.{ 0, 13 }, .start, &mock, 0, 14, 17);
        try testBackwardsByWord(.{ 0, 10 }, .start, &mock, 0, 11, 13);
        try testBackwardsByWord(.{ 0, 9 }, .start, &mock, 0, 10, 10);
        try testBackwardsByWord(.{ 0, 7 }, .start, &mock, 0, 8, 9);
        try testBackwardsByWord(.{ 0, 4 }, .start, &mock, 0, 5, 7);
        try testBackwardsByWord(.{ 0, 3 }, .start, &mock, 0, 4, 4);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 0, 0, 3);
    }
    {
        var mock = try Mockery.init(testing_allocator, "one\ntwo");
        //                                              012  012
        defer mock.deinit();
        try testBackwardsByWord(.{ 1, 0 }, .start, &mock, 1, 1, 2);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 1, 0, 0);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 0, 0, 2);
    }
    {
        var mock = try Mockery.init(testing_allocator, "draw forth\na map");
        //                                              0    5      0 2
        defer mock.deinit();
        try testBackwardsByWord(.{ 1, 2 }, .start, &mock, 1, 3, 4);
        try testBackwardsByWord(.{ 1, 0 }, .start, &mock, 1, 1, 2);
        try testBackwardsByWord(.{ 0, 5 }, .start, &mock, 1, 0, 0);
        try testBackwardsByWord(.{ 0, 5 }, .start, &mock, 0, 6, 10);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 0, 0, 5);
    }
    {
        var mock = try Mockery.init(testing_allocator, "draw forth;\na map");
        //                                              0    5    0 0 2
        defer mock.deinit();
        try testBackwardsByWord(.{ 1, 2 }, .start, &mock, 1, 3, 4);
        try testBackwardsByWord(.{ 1, 0 }, .start, &mock, 1, 1, 2);
        try testBackwardsByWord(.{ 0, 10 }, .start, &mock, 1, 0, 0);
        try testBackwardsByWord(.{ 0, 5 }, .start, &mock, 0, 6, 10);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 0, 0, 5);
    }
    {
        var mock = try Mockery.init(testing_allocator, "hello world\n\nand mars");
        //                                              0     6      0 0   4  7
        defer mock.deinit();
        try testBackwardsByWord(.{ 2, 4 }, .start, &mock, 2, 5, 7);
        try testBackwardsByWord(.{ 2, 0 }, .start, &mock, 2, 1, 4);
        try testBackwardsByWord(.{ 1, 0 }, .start, &mock, 2, 0, 0);
        try testBackwardsByWord(.{ 0, 6 }, .start, &mock, 1, 0, 0);
        try testBackwardsByWord(.{ 0, 6 }, .start, &mock, 0, 7, 10);
        try testBackwardsByWord(.{ 0, 0 }, .start, &mock, 0, 0, 6);
    }
    // .end
    {
        {
            var mock = try Mockery.init(testing_allocator, "one;two--3|||four;;;;");
            //                                              0 23  6 89  2   6   0
            defer mock.deinit();
            try testBackwardsByWord(.{ 0, 16 }, .end, &mock, 0, 17, 20);
            try testBackwardsByWord(.{ 0, 12 }, .end, &mock, 0, 13, 16);
            try testBackwardsByWord(.{ 0, 9 }, .end, &mock, 0, 10, 12);
            try testBackwardsByWord(.{ 0, 8 }, .end, &mock, 0, 9, 9);
            try testBackwardsByWord(.{ 0, 6 }, .end, &mock, 0, 7, 8);
            try testBackwardsByWord(.{ 0, 3 }, .end, &mock, 0, 4, 6);
            try testBackwardsByWord(.{ 0, 2 }, .end, &mock, 0, 3, 3);
            try testBackwardsByWord(.{ 0, 0 }, .end, &mock, 0, 0, 2);
        }
        {
            var mock = try Mockery.init(testing_allocator, "draw forth\na map");
            //                                              0  3     9  0
            defer mock.deinit();
            try testBackwardsByWord(.{ 1, 0 }, .end, &mock, 1, 1, 4);
            try testBackwardsByWord(.{ 0, 9 }, .end, &mock, 1, 0, 0);
            try testBackwardsByWord(.{ 0, 3 }, .end, &mock, 0, 4, 8);
            try testBackwardsByWord(.{ 0, 0 }, .end, &mock, 0, 0, 3);
        }
        {
            var mock = try Mockery.init(testing_allocator, "draw forth\nmy map");
            //                                              0  3     9   1
            defer mock.deinit();
            try testBackwardsByWord(.{ 1, 1 }, .end, &mock, 1, 2, 5);
            try testBackwardsByWord(.{ 0, 9 }, .end, &mock, 1, 0, 1);
            try testBackwardsByWord(.{ 0, 3 }, .end, &mock, 0, 4, 9);
            try testBackwardsByWord(.{ 0, 0 }, .end, &mock, 0, 0, 3);
        }
        {
            var mock = try Mockery.init(testing_allocator, "draw forth;\nmy map");
            //                                              0  3     90  1
            defer mock.deinit();
            try testBackwardsByWord(.{ 1, 1 }, .end, &mock, 1, 2, 5);
            try testBackwardsByWord(.{ 0, 10 }, .end, &mock, 1, 0, 1);
            try testBackwardsByWord(.{ 0, 9 }, .end, &mock, 0, 10, 10);
            try testBackwardsByWord(.{ 0, 3 }, .end, &mock, 0, 4, 9);
            try testBackwardsByWord(.{ 0, 0 }, .end, &mock, 0, 0, 3);
        }
    }
}

fn testBackwardsByWord(expected: struct { usize, usize }, boundary_type: WordBoundaryType, mock: *Mockery, linenr: usize, start_col: usize, end_col: usize) !void {
    for (start_col..end_col + 1) |colnr| {
        const result = backwardsByWord(testing_allocator, boundary_type, mock, Mockery.getLine, linenr, colnr);
        try eq(expected, result);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Line = []const u21;

fn createLinesFromSource(a: Allocator, source: []const u8) ![]Line {
    var lines = std.ArrayList(Line).init(a);
    var line_start: usize = 0;
    for (source, 0..) |byte, i| {
        if (byte == '\n') {
            const new_line = try createLine(a, source[line_start..i]);
            try lines.append(new_line); // '\n' NOT INCLUDED at end of line
            defer line_start = i + 1;
        }
    }
    if (line_start < source.len) {
        const last_line = try createLine(a, source[line_start..]);
        if (last_line.len > 0) try lines.append(last_line);
    }
    return try lines.toOwnedSlice();
}

pub fn createLine(a: Allocator, source: []const u8) !Line {
    var cells = try std.ArrayList(u21).initCapacity(a, source.len);
    var iter = code_point.Iterator{ .bytes = source };
    while (iter.next()) |cp| try cells.append(cp.code);
    return try cells.toOwnedSlice();
}

test createLine {
    {
        const line = try createLine(testing_allocator, "Hello");
        defer testing_allocator.free(line);
        try eq('H', line[0]);
        try eq('e', line[1]);
        try eq('l', line[2]);
        try eq('l', line[3]);
        try eq('o', line[4]);
    }
    {
        const line = try createLine(testing_allocator, "안녕하세요! Hello there 👋!");
        defer testing_allocator.free(line);
        try eq('안', line[0]);
        try eq('녕', line[1]);
        try eq('하', line[2]);
        try eq('세', line[3]);
        try eq('요', line[4]);
        try eq('!', line[5]);
        try eq('👋', line[line.len - 2]);
        try eq('!', line[line.len - 1]);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CharType = enum {
    space,
    word,
    symbol,
    null,

    fn fromChar(may_char: ?u21) CharType {
        if (may_char) |char| {
            if (isSpace(char)) return .space;
            if (isSymbol(char)) return .symbol;
            return .word;
        }
        return .null;
    }
};

pub const WordBoundaryType = enum {
    start,
    end,
    both,
    not_a_boundary,
};

fn getCharBoundaryType(prev: ?u21, curr: u21, next: ?u21) WordBoundaryType {
    const curr_type = CharType.fromChar(curr);
    if (curr_type == .space) return .not_a_boundary;
    const prev_type = CharType.fromChar(prev);
    const next_type = CharType.fromChar(next);

    var curr_boundary_type: WordBoundaryType = .not_a_boundary;
    if (prev_type != curr_type) curr_boundary_type = .start;
    if (curr_type != next_type) {
        if (curr_boundary_type == .start) return .both;
        return .end;
    }

    return curr_boundary_type;
}

test getCharBoundaryType {
    try eq(.not_a_boundary, getCharBoundaryType('a', 'b', 'c'));
    try eq(.not_a_boundary, getCharBoundaryType('a', ' ', 'c'));
    try eq(.start, getCharBoundaryType(' ', 'a', 'c'));
    try eq(.start, getCharBoundaryType(';', 'a', 'c'));
    try eq(.end, getCharBoundaryType('a', 'b', ' '));
    try eq(.end, getCharBoundaryType('a', 'b', ';'));
    try eq(.both, getCharBoundaryType(' ', 'a', ' '));
    try eq(.both, getCharBoundaryType(' ', 'a', ';'));
    try eq(.both, getCharBoundaryType('h', ';', null));
}

fn foundTargetBoundary(line: Line, colnr: usize, boundary_type: WordBoundaryType) bool {
    if (line.len == 0) return true;
    const prev_char = if (colnr == 0) null else line[colnr - 1];
    const curr_char = line[colnr];
    const next_char = if (colnr + 1 >= line.len) null else line[colnr + 1];
    const char_boundary_type = getCharBoundaryType(prev_char, curr_char, next_char);
    if (char_boundary_type == boundary_type or char_boundary_type == .both) return true;
    return false;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn isSpace(c: u21) bool {
    return switch (c) {
        ' ' => true,
        '\t' => true,
        '\n' => true,
        else => false,
    };
}

fn isSymbol(c: u21) bool {
    return switch (c) {
        '=' => true,
        '"' => true,
        '\'' => true,
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
        '-' => true,
        else => false,
    };
}
