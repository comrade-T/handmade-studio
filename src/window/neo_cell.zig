const std = @import("std");
const code_point = @import("code_point");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

const Line = [][]const u8;

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

fn foundTargetBoundary(line: Line, colnr: usize, boundary_type: WordBoundaryType) !void {
    const prev_char = if (colnr == 0) null else line[colnr - 1];
    const curr_char = line[colnr];
    const next_char = if (colnr >= line.len) null else line[colnr + 1];
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
