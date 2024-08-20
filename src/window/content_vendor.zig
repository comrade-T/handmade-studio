const std = @import("std");
const ztracy = @import("ztracy");
const _neo_buffer = @import("neo_buffer");
const code_point = _neo_buffer.code_point;
const ts = _neo_buffer.ts;
const Buffer = _neo_buffer.Buffer;
const PredicatesFilter = _neo_buffer.PredicatesFilter;
const SupportedLanguages = _neo_buffer.SupportedLanguages;

const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn getTSQuery(lang: SupportedLanguages) !*ts.Query {
    const get_lang_zone = ztracy.ZoneNC(@src(), "ts.Language.get()", 0xFF00FF);
    const tslang = switch (lang) {
        .zig => try ts.Language.get("zig"),
    };
    get_lang_zone.End();

    const create_query_zone = ztracy.ZoneNC(@src(), "ts.Query.create()", 0x00AAFF);
    const patterns = switch (lang) {
        .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
    };
    const query = try ts.Query.create(tslang, patterns);
    create_query_zone.End();

    return query;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return r << 24 | g << 16 | b << 8 | a;
}

const RAY_WHITE = rgba(245, 245, 245, 245);

pub fn createHighlightMap(a: Allocator) !std.StringHashMap(u32) {
    var map = std.StringHashMap(u32).init(a);
    try map.put("__blank", rgba(0, 0, 0, 0)); // \n
    try map.put("variable", rgba(245, 245, 245, 245)); // identifier ray_white
    try map.put("type.qualifier", rgba(200, 122, 255, 255)); // const purple
    try map.put("type", rgba(0, 117, 44, 255)); // Allocator dark_green
    try map.put("function.builtin", rgba(0, 121, 241, 255)); // @import blue
    try map.put("include", rgba(230, 41, 55, 255)); // @import red
    try map.put("boolean", rgba(230, 41, 55, 255)); // true red
    try map.put("string", rgba(253, 249, 0, 255)); // "hello" yellow
    try map.put("punctuation.bracket", rgba(255, 161, 0, 255)); // () orange
    try map.put("punctuation.delimiter", rgba(255, 161, 0, 255)); // ; orange
    try map.put("number", rgba(255, 161, 0, 255)); // 12 orange
    try map.put("field", rgba(0, 121, 241, 255)); // std.'mem' blue
    return map;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Highlighter = struct {
    a: Allocator,
    buffer: *Buffer,
    query: *ts.Query,
    hl_map: *std.StringHashMap(u32),
    filter: *PredicatesFilter,

    const DEFAULT_COLOR = rgba(245, 245, 245, 245);

    pub fn init(a: Allocator, buffer: *Buffer, hl_map: *std.StringHashMap(u32), query: *ts.Query) !*const @This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .buffer = buffer,
            .query = query,
            .hl_map = hl_map,
            .filter = try PredicatesFilter.initWithContentCallback(a, self.query, Buffer.contentCallback, self.buffer),
        };
        return self;
    }

    pub fn deinit(self: *const @This()) void {
        self.filter.deinit();
        self.a.destroy(self);
    }

    pub fn requestLines(self: *const @This(), a: Allocator, start_line: usize, end_line: usize) !*Iterator {
        return Iterator.init(a, self, start_line, end_line);
    }

    pub const Iterator = struct {
        arena: ArenaAllocator,
        exa: Allocator,
        parent: *const Highlighter,

        start_line: usize,
        end_line: usize,

        current_line_index: usize = 0,
        current_line_offset: usize = 0,

        lines: ArrayList([]const u8),

        highlights: []u32 = undefined,
        highlight_offset: usize = 0,

        pub fn init(a: Allocator, parent: *const Highlighter, start_line: usize, end_line: usize) !*Iterator {
            if (end_line <= start_line) return error.EndLineSmallerOrEqualToStartLine;

            const num_of_lines_in_document = parent.buffer.roperoot.weights().bols;
            const adjusted_end_line = if (end_line < num_of_lines_in_document) end_line else num_of_lines_in_document;

            const zone = ztracy.ZoneNC(@src(), "Highlighter.Iterator.init()", 0x00AAFF);
            defer zone.End();

            const self = try parent.a.create(@This());
            self.* = .{
                .arena = ArenaAllocator.init(a),
                .exa = a,
                .parent = parent,

                .start_line = start_line,
                .end_line = adjusted_end_line,

                .lines = try ArrayList([]const u8).initCapacity(self.arena.allocator(), adjusted_end_line - start_line),
            };

            try self.addLineContents();
            try self.addLineHighlights();

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.exa.destroy(self);
        }

        pub fn update(self: *@This(), new_start_line: usize, new_end_line: usize) !*Iterator {
            const old_self = self;
            defer old_self.deinit();
            return Iterator.init(self.exa, self.parent, new_start_line, new_end_line);
        }

        pub fn reset(self: *@This()) void {
            self.current_line_index = 0;
            self.current_line_offset = 0;
            self.highlight_offset = 0;
        }

        const NextCharResult = struct {
            code_point: u21,
            color: u32,
        };

        pub fn skipLine(self: *@This()) void {
            const highliight_indexes_to_skip = self.lines.items[self.current_line_index].len - self.current_line_offset;
            self.highlight_offset += highliight_indexes_to_skip;
            self.current_line_offset = 0;
            self.current_line_index += 1;
        }

        pub fn nextChar(self: *@This()) ?NextCharResult {
            const _tracy = ztracy.ZoneNC(@src(), "Iterator.nextChar()", 0xFF00FF);
            defer _tracy.End();

            if (self.current_line_offset >= self.lines.items[self.current_line_index].len) {
                self.current_line_index += 1;
                self.current_line_offset = 0;
                if (self.current_line_index + self.start_line >= self.end_line) return null;
            }

            var cp_iter = code_point.Iterator{ .i = @intCast(self.current_line_offset), .bytes = self.lines.items[self.current_line_index] };
            if (cp_iter.next()) |cp| {
                defer self.current_line_offset += cp.len;
                defer self.highlight_offset += cp.len;
                const color = self.highlights[self.highlight_offset];
                return .{ .code_point = cp.code, .color = color };
            }

            return null;
        }

        fn addLineContents(self: *@This()) !void {
            const zone = ztracy.ZoneNC(@src(), "Iterator.addLineContents()", 0x00AAFF);
            defer zone.End();

            for (self.start_line..self.end_line) |linenr| {
                const line_content = try self.parent.buffer.roperoot.getLine(self.arena.allocator(), linenr);
                try self.lines.append(line_content);
            }
        }

        fn addLineHighlights(self: *@This()) !void {
            const _tracy = ztracy.ZoneNC(@src(), "Iterator.addLineHighlights()", 0x000099);
            defer _tracy.End();

            const area_start_offset = try self.parent.buffer.roperoot.getByteOffsetOfPosition(self.start_line, 0);
            var arena_end_offset = area_start_offset;
            for (self.lines.items) |line| arena_end_offset += line.len;

            self.highlights = try self.arena.allocator().alloc(u32, arena_end_offset - area_start_offset);
            @memset(self.highlights, DEFAULT_COLOR);

            const cursor = try ts.Query.Cursor.create();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(self.start_line), .column = 0 },
                ts.Point{ .row = @intCast(self.end_line + 1), .column = 0 },
            );
            cursor.execute(self.parent.query, self.parent.buffer.tstree.?.getRootNode());
            defer cursor.destroy();

            while (true) {
                const result = self.parent.filter.nextMatchInLines(self.parent.query, cursor, self.start_line, self.end_line);
                switch (result) {
                    .match => |match| if (match.match == null) break,
                    .ignore => break,
                }

                const match = result.match;
                const color = if (self.parent.hl_map.get(match.cap_name)) |color| color else RAY_WHITE;
                const start = @max(match.cap_node.?.getStartByte(), area_start_offset) -| area_start_offset;
                const end = @min((match.cap_node.?.getEndByte()), arena_end_offset) -| area_start_offset;

                if (start < end) @memset(self.highlights[start..end], color);
            }
        }
    };

    test Iterator {
        var hl_map = try createHighlightMap(testing_allocator);
        defer hl_map.deinit();
        {
            const iter = try setupTestIter("const", &hl_map, 0, 1);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const Allocator = @import(\"std\").mem.Allocator;", &hl_map, 0, 1);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, " ", "variable");
            try testIter(iter, "Allocator", "type");
            try testIter(iter, " = ", "variable");
            try testIter(iter, "@import", "include");
            try testIter(iter, "(", "punctuation.bracket");
            try testIter(iter, "\"std\"", "string");
            try testIter(iter, ")", "punctuation.bracket");
            try testIter(iter, ".", "punctuation.delimiter");
            try testIter(iter, "mem", "field");
            try testIter(iter, ".", "punctuation.delimiter");
            try testIter(iter, "Allocator", "type");
            try testIter(iter, ";", "punctuation.delimiter");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const a = 10;\nvar not_false = true;", &hl_map, 0, 2);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, " a = ", "variable");
            try testIter(iter, "10", "number");
            try testIter(iter, ";", "punctuation.delimiter");
            try testIter(iter, "\n", "variable");
            try testIter(iter, "var", "type.qualifier");
            try testIter(iter, " not_false = ", "variable");
            try testIter(iter, "true", "boolean");
            try testIter(iter, ";", "punctuation.delimiter");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const a = 10;\nvar not_false = true;", &hl_map, 1, 2);
            defer teardownTestIer(iter);
            try testIter(iter, "var", "type.qualifier");
            try testIter(iter, " not_false = ", "variable");
            try testIter(iter, "true", "boolean");
            try testIter(iter, ";", "punctuation.delimiter");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const\n", &hl_map, 0, 999);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, "\n", "variable");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const\n\n", &hl_map, 0, 999);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, "\n", "variable");
            try testIter(iter, "\n", "variable");
            try testIter(iter, null, null);
        }
        {
            const iter = try setupTestIter("const\n\nsomething", &hl_map, 0, 999);
            defer teardownTestIer(iter);
            try testIter(iter, "const", "type.qualifier");
            try testIter(iter, "\n", "variable");
            try testIter(iter, "\n", "variable");
            try testIter(iter, "something", "variable");
            try testIter(iter, null, null);
        }
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn testIter(iter: *Highlighter.Iterator, expected_sequence: ?[]const u8, expected_group: ?[]const u8) !void {
    if (expected_sequence == null) {
        try eq(null, iter.nextChar());
        return;
    }
    var code_point_iter = code_point.Iterator{ .bytes = expected_sequence.? };
    var i: usize = 0;
    while (code_point_iter.next()) |cp| {
        const result = iter.nextChar();
        try eq(cp.code, result.?.code_point);
        try eq(iter.parent.hl_map.get(expected_group.?).?, result.?.color);
        defer i += 1;
    }
}
fn setupTestIter(source: []const u8, hl_map: *std.StringHashMap(u32), start_line: usize, end_line: usize) !*Highlighter.Iterator {
    const query = try getTSQuery(.zig);
    var buf = try Buffer.create(testing_allocator, .string, source);
    try buf.initiateTreeSitter(.zig);
    const highlighter = try Highlighter.init(testing_allocator, buf, hl_map, query);
    const iter = try highlighter.requestLines(testing_allocator, start_line, end_line);
    return iter;
}
fn teardownTestIer(iter: *Highlighter.Iterator) void {
    iter.parent.buffer.destroy();
    iter.parent.query.destroy();
    iter.parent.deinit();
    iter.deinit();
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(Highlighter);
}
