const std = @import("std");
const code_point = @import("code_point");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn backwardsByWord(destination: WordBoundaryType, lines: []Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    var linenr, var colnr = bringPositionInBound(lines, input_linenr, input_colnr);
    colnr -|= 1;
    while (true) {
        defer colnr -|= 1;
        if (colnr == 0) {
            if (linenr == 0) return .{ 0, 0 };
            if (input_colnr > 0 and foundTargetBoundary(lines[linenr], colnr, destination)) return .{ linenr, colnr };
            linenr -= 1;
            colnr = lines[linenr].len - 1;
        }
        if (foundTargetBoundary(lines[linenr], colnr, destination)) return .{ linenr, colnr };
    }
    return .{ linenr, colnr };
}

test backwardsByWord {
    // .start
    {
        const lines = try createLinesFromSource(testing_allocator, "one;two--3|||four;");
        //                                                          0  34  7 90  3   7
        defer freeLines(testing_allocator, lines);
        try testBackwardsByWord(.{ 0, 13 }, .start, lines, 0, 14, 17);
        try testBackwardsByWord(.{ 0, 10 }, .start, lines, 0, 11, 13);
        try testBackwardsByWord(.{ 0, 9 }, .start, lines, 0, 10, 10);
        try testBackwardsByWord(.{ 0, 7 }, .start, lines, 0, 8, 9);
        try testBackwardsByWord(.{ 0, 4 }, .start, lines, 0, 5, 7);
        try testBackwardsByWord(.{ 0, 3 }, .start, lines, 0, 4, 4);
        try testBackwardsByWord(.{ 0, 0 }, .start, lines, 0, 0, 3);
    }
}

fn testBackwardsByWord(expeced: struct { usize, usize }, boundary_type: WordBoundaryType, lines: []Line, linenr: usize, start_col: usize, end_col: usize) !void {
    for (start_col..end_col + 1) |colnr| {
        const result = backwardsByWord(boundary_type, lines, linenr, colnr);
        try eq(expeced, result);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn forwardByWord(destination: WordBoundaryType, lines: []Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    var linenr, var colnr = bringPositionInBound(lines, input_linenr, input_colnr);
    if (linenr == lines.len -| 1 and colnr == lines[lines.len -| 1].len -| 1) return .{ linenr, colnr };
    colnr += 1;
    while (true) {
        defer colnr += 1;
        if (colnr >= lines[linenr].len) {
            if (linenr == lines.len - 1) return .{ linenr, lines[linenr].len - 1 };
            linenr += 1;
            colnr = 0;
        }
        if (foundTargetBoundary(lines[linenr], colnr, destination)) return .{ linenr, colnr };
    }
}

test forwardByWord {
    // .end
    {
        const lines = try createLinesFromSource(testing_allocator, "hello world");
        //                                                              4     0
        defer freeLines(testing_allocator, lines);
        try testForwardByWord(.{ 0, 4 }, .end, lines, 0, 0, 3);
        try testForwardByWord(.{ 0, 10 }, .end, lines, 0, 4, 10);
        try testForwardByWord(.{ 0, 10 }, .end, lines, 0, 11, 100); // out of bounds
    }
    {
        const lines = try createLinesFromSource(testing_allocator, "one#two--3|||four;;;;");
        //                                                            23  6 89  2   6   0
        defer freeLines(testing_allocator, lines);
        try testForwardByWord(.{ 0, 2 }, .end, lines, 0, 0, 1);
        try testForwardByWord(.{ 0, 3 }, .end, lines, 0, 2, 2);
        try testForwardByWord(.{ 0, 6 }, .end, lines, 0, 3, 5);
        try testForwardByWord(.{ 0, 8 }, .end, lines, 0, 6, 7);
        try testForwardByWord(.{ 0, 9 }, .end, lines, 0, 8, 8);
        try testForwardByWord(.{ 0, 12 }, .end, lines, 0, 9, 11);
        try testForwardByWord(.{ 0, 16 }, .end, lines, 0, 12, 15);
        try testForwardByWord(.{ 0, 20 }, .end, lines, 0, 16, 19);
    }
    {
        const lines = try createLinesFromSource(testing_allocator, "draw forth\nmy map");
        //                                                             3     9   1   5
        defer freeLines(testing_allocator, lines);
        try testForwardByWord(.{ 0, 3 }, .end, lines, 0, 0, 2);
        try testForwardByWord(.{ 0, 9 }, .end, lines, 0, 3, 8);
        try testForwardByWord(.{ 1, 1 }, .end, lines, 0, 9, 9);
        try testForwardByWord(.{ 1, 1 }, .end, lines, 1, 0, 0);
        try testForwardByWord(.{ 1, 5 }, .end, lines, 1, 1, 4);
        try testForwardByWord(.{ 1, 5 }, .end, lines, 1, 5, 100); // out of bounds
    }
    // start
    {
        {
            const lines = try createLinesFromSource(testing_allocator, "hello world");
            //                                                                6   0
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 6 }, .start, lines, 0, 0, 5);
            try testForwardByWord(.{ 0, 10 }, .start, lines, 0, 6, 9);
            try testForwardByWord(.{ 0, 10 }, .start, lines, 0, 10, 100); // out of bounds
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello; world");
            //                                                               5 7   1
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 5 }, .start, lines, 0, 0, 4);
            try testForwardByWord(.{ 0, 7 }, .start, lines, 0, 5, 6);
            try testForwardByWord(.{ 0, 11 }, .start, lines, 0, 7, 11);
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello ; world");
            //                                                                6 8   2
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 6 }, .start, lines, 0, 0, 5);
            try testForwardByWord(.{ 0, 8 }, .start, lines, 0, 6, 7);
            try testForwardByWord(.{ 0, 12 }, .start, lines, 0, 8, 12);
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello ;; world");
            //                                                                6  9   3
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 6 }, .start, lines, 0, 0, 5);
            try testForwardByWord(.{ 0, 9 }, .start, lines, 0, 6, 8);
            try testForwardByWord(.{ 0, 13 }, .start, lines, 0, 9, 13);
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello  world one  two");
            //                                                                 7     3    8 0
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 7 }, .start, lines, 0, 0, 6);
            try testForwardByWord(.{ 0, 13 }, .start, lines, 0, 7, 12);
            try testForwardByWord(.{ 0, 18 }, .start, lines, 0, 13, 17);
            try testForwardByWord(.{ 0, 20 }, .start, lines, 0, 18, 20);
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "one|two||3|||four");
            //                                                             34  7 90  3  6
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 3 }, .start, lines, 0, 0, 2);
            try testForwardByWord(.{ 0, 4 }, .start, lines, 0, 3, 3);
            try testForwardByWord(.{ 0, 7 }, .start, lines, 0, 4, 6);
            try testForwardByWord(.{ 0, 9 }, .start, lines, 0, 7, 8);
            try testForwardByWord(.{ 0, 10 }, .start, lines, 0, 9, 9);
            try testForwardByWord(.{ 0, 13 }, .start, lines, 0, 10, 12);
            try testForwardByWord(.{ 0, 16 }, .start, lines, 0, 13, 16);
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "const std = @import(\"std\");\nconst");
            //                                                          0     6   0 2      9  1   4    0   4
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 6 }, .start, lines, 0, 0, 5);
            try testForwardByWord(.{ 0, 10 }, .start, lines, 0, 6, 9);
            try testForwardByWord(.{ 0, 12 }, .start, lines, 0, 10, 11);
            try testForwardByWord(.{ 0, 19 }, .start, lines, 0, 12, 18);
            try testForwardByWord(.{ 0, 21 }, .start, lines, 0, 19, 20);
            try testForwardByWord(.{ 0, 24 }, .start, lines, 0, 21, 23);
            try testForwardByWord(.{ 1, 0 }, .start, lines, 0, 24, 26);
            try testForwardByWord(.{ 1, 0 }, .start, lines, 0, 27, 100); // out of bounds on line 0
            try testForwardByWord(.{ 1, 4 }, .start, lines, 1, 0, 3);
            try testForwardByWord(.{ 1, 4 }, .start, lines, 1, 4, 100); // out of bounds on line 1
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello\nworld\nvenus\nmars");
            //                                                          0      0      0      0  3
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 1, 0 }, .start, lines, 0, 0, 4);
            try testForwardByWord(.{ 2, 0 }, .start, lines, 1, 0, 4);
            try testForwardByWord(.{ 3, 0 }, .start, lines, 2, 0, 4);
            try testForwardByWord(.{ 3, 3 }, .start, lines, 3, 0, 2);
            try testForwardByWord(.{ 3, 3 }, .start, lines, 3, 3, 100); // out of bouds on line 3
        }
        {
            const lines = try createLinesFromSource(testing_allocator, "hello world\nvenus and mars");
            //                                                          0     6      0     6   0  3
            defer freeLines(testing_allocator, lines);
            try testForwardByWord(.{ 0, 6 }, .start, lines, 0, 0, 5);
            try testForwardByWord(.{ 1, 0 }, .start, lines, 0, 6, 10);
            try testForwardByWord(.{ 1, 6 }, .start, lines, 1, 0, 5);
            try testForwardByWord(.{ 1, 10 }, .start, lines, 1, 6, 9);
            try testForwardByWord(.{ 1, 13 }, .start, lines, 1, 10, 13);
        }
    }
}

fn testForwardByWord(expeced: struct { usize, usize }, boundary_type: WordBoundaryType, lines: []Line, linenr: usize, start_col: usize, end_col: usize) !void {
    for (start_col..end_col + 1) |colnr| {
        const result = forwardByWord(boundary_type, lines, linenr, colnr);
        try eq(expeced, result);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn bringPositionInBound(lines: []Line, input_linenr: usize, input_colnr: usize) struct { usize, usize } {
    var linenr, var colnr = .{ input_linenr, input_colnr };
    if (linenr > lines.len -| 1) {
        linenr = lines.len -| 1;
        colnr = lines[linenr].len -| 1;
        return .{ linenr, colnr };
    }
    if (colnr > lines[linenr].len -| 1) colnr = lines[linenr].len -| 1;
    return .{ linenr, colnr };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Line = [][]const u8;

fn createLinesFromSource(a: Allocator, source: []const u8) ![]Line {
    var lines = std.ArrayList(Line).init(a);
    var line_start: usize = 0;
    for (source, 0..) |byte, i| {
        if (byte == '\n') {
            const new_line = try createLine(a, source[line_start .. i + 1]);
            try lines.append(new_line); // '\n' included at end of line
            defer line_start = i + 1;
        }
    }
    if (line_start < source.len) {
        const last_line = try createLine(a, source[line_start..]);
        if (last_line.len > 0) try lines.append(last_line);
    }
    return try lines.toOwnedSlice();
}
fn freeLines(a: Allocator, lines: []Line) void {
    for (lines) |line| a.free(line);
    a.free(lines);
}

fn createLine(a: Allocator, source: []const u8) !Line {
    var cells = try std.ArrayList([]const u8).initCapacity(a, source.len);
    var iter = code_point.Iterator{ .bytes = source };
    while (iter.next()) |cp| try cells.append(source[cp.offset .. cp.offset + cp.len]);
    return try cells.toOwnedSlice();
}

test createLine {
    {
        const line = try createLine(testing_allocator, "Hello");
        defer testing_allocator.free(line);
        try eqStr("H", line[0]);
        try eqStr("e", line[1]);
        try eqStr("l", line[2]);
        try eqStr("l", line[3]);
        try eqStr("o", line[4]);
    }
    {
        const line = try createLine(testing_allocator, "안녕하세요! Hello there 👋!");
        defer testing_allocator.free(line);
        try eqStr("안", line[0]);
        try eqStr("녕", line[1]);
        try eqStr("하", line[2]);
        try eqStr("세", line[3]);
        try eqStr("요", line[4]);
        try eqStr("!", line[5]);
        try eqStr("👋", line[line.len - 2]);
        try eqStr("!", line[line.len - 1]);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const CharType = enum {
    space,
    word,
    symbol,
    null,

    fn fromChar(may_char: ?[]const u8) CharType {
        if (may_char) |char| {
            if (isSpace(char)) return .space;
            if (isSymbol(char)) return .symbol;
            return .word;
        }
        return .null;
    }
};

const WordBoundaryType = enum {
    start,
    end,
    both,
    not_a_boundary,
};

fn getCharBoundaryType(prev: ?[]const u8, curr: []const u8, next: ?[]const u8) WordBoundaryType {
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
    try eq(.not_a_boundary, getCharBoundaryType("a", "b", "c"));
    try eq(.not_a_boundary, getCharBoundaryType("a", " ", "c"));
    try eq(.start, getCharBoundaryType(" ", "a", "c"));
    try eq(.start, getCharBoundaryType(";", "a", "c"));
    try eq(.end, getCharBoundaryType("a", "b", " "));
    try eq(.end, getCharBoundaryType("a", "b", ";"));
    try eq(.both, getCharBoundaryType(" ", "a", " "));
    try eq(.both, getCharBoundaryType(" ", "a", ";"));
    try eq(.both, getCharBoundaryType("h", ";", null));
}

fn foundTargetBoundary(line: Line, colnr: usize, boundary_type: WordBoundaryType) bool {
    const prev_char = if (colnr == 0) null else line[colnr - 1];
    const curr_char = line[colnr];
    const next_char = if (colnr + 1 >= line.len) null else line[colnr + 1];
    const char_boundary_type = getCharBoundaryType(prev_char, curr_char, next_char);
    if (char_boundary_type == boundary_type or char_boundary_type == .both) return true;
    return false;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn isSpace(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
        ' ' => true,
        '\t' => true,
        '\n' => true,
        else => false,
    };
}

fn isSymbol(c: []const u8) bool {
    if (c.len == 0) return true;
    return switch (c[0]) {
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
