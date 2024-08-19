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

fn getTSQuery(lang: SupportedLanguages) !*ts.Query {
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

fn createHighlightMap(a: Allocator) !std.StringHashMap(u32) {
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

pub const ContentVendor = struct {
    a: Allocator,
    buffer: *Buffer,
    query: *ts.Query,
    filter: *PredicatesFilter,
    hl_map: std.StringHashMap(u32),

    pub fn init(a: Allocator, buffer: *Buffer) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .buffer = buffer,
            .query = try getTSQuery(buffer.lang.?),
            .filter = try PredicatesFilter.initWithContentCallback(a, self.query, Buffer.contentCallback, self.buffer),
            .hl_map = try createHighlightMap(a),
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.query.destroy();
        self.filter.deinit();
        self.hl_map.deinit();
        self.a.destroy(self);
    }

    ///////////////////////////// Job

    const DEFAULT_COLOR = rgba(245, 245, 245, 245);
    const JOB_BUF_SIZE = 1024;

    pub const CurrentJobIterator = struct {
        a: Allocator,
        vendor: *ContentVendor,

        start_line: usize,
        end_line: usize,
        current_line: usize,

        buf: [JOB_BUF_SIZE + 1]u8 = undefined,

        line: ?[]const u8,
        line_byte_offset: usize,
        line_start_byte: u32, // (relative to document)
        line_end_byte: u32, // (relative to document)

        highlights: ?[]u32,

        pub fn init(a: Allocator, vendor: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
            const zone = ztracy.ZoneNC(@src(), "ContentVendor.init()", 0x00AAFF);
            defer zone.End();

            const self = try a.create(@This());
            self.* = .{
                .a = a,
                .vendor = vendor,

                .start_line = start_line,
                .end_line = end_line,
                .current_line = start_line,

                .line = null,
                .line_byte_offset = 0,
                .line_start_byte = 0,
                .line_end_byte = 0,

                .highlights = null,
            };

            const update_line_zone = ztracy.ZoneNC(@src(), "PredicatesFilter.init().updateLineContent()", 0x00AAFF);
            self.updateLineContent() catch |err| switch (err) {
                error.EndOfDocument => {},
                else => @panic("error calling self.updateLineContent() on CurrentJobIterator.init()"),
            };
            update_line_zone.End();

            const update_highlights_zone = ztracy.ZoneNC(@src(), "PredicatesFilter.init().updateLineHighlights()", 0x00FFAA);
            try self.updateLineHighlights();
            update_highlights_zone.End();

            return self;
        }

        pub fn deinit(self: *@This()) void {
            if (self.highlights) |highlights| self.a.free(highlights);
            self.a.destroy(self);
        }

        fn updateLineContent(self: *@This()) !void {
            const tracy_zone = ztracy.ZoneNC(@src(), "updateLineContent()", 0x00AAFF);
            defer tracy_zone.End();

            const start_byte = if (self.line == null)
                try self.vendor.buffer.roperoot.getByteOffsetOfPosition(self.current_line, 0)
            else
                self.line_end_byte;

            const line_content, const eol = self.vendor.buffer.roperoot.getRestOfLine(start_byte, &self.buf, JOB_BUF_SIZE);
            if (eol) {
                self.buf[line_content.len] = '\n';
                self.line = self.buf[0 .. line_content.len + 1];
            } else {
                self.line = line_content;
            }

            if (self.line_end_byte >= self.vendor.buffer.roperoot.weights().len) return error.EndOfDocument;

            const line_end_byte = start_byte + self.line.?.len;
            self.line_start_byte = @intCast(start_byte);
            self.line_end_byte = @intCast(line_end_byte);
            self.line_byte_offset = 0;
        }

        fn updateLineHighlights(self: *@This()) !void {
            const tracy_zone = ztracy.ZoneNC(@src(), "updateLineHighlights()", 0xAA00FF);
            defer tracy_zone.End();

            if (self.line) |line| if (line.len == 0) return;

            const memset_zone = ztracy.ZoneNC(@src(), "memset_zone()", 0xAA9900);
            if (self.highlights) |highlights| self.a.free(highlights);
            self.highlights = try self.a.alloc(u32, self.line.?.len);
            @memset(self.highlights.?, DEFAULT_COLOR);
            memset_zone.End();

            const cursor_execute_zone = ztracy.ZoneNC(@src(), "cursor_execute_zone()", 0xAA0000);
            const cursor = try ts.Query.Cursor.create();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(self.current_line), .column = 0 },
                ts.Point{ .row = @intCast(self.end_line + 1), .column = 0 },
            );
            cursor.execute(self.vendor.query, self.vendor.buffer.tstree.?.getRootNode());
            cursor_execute_zone.End();
            defer cursor.destroy();

            while (true) {
                const while_zone = ztracy.ZoneNC(@src(), "while_zone", 0xAA0066);
                defer while_zone.End();

                const result = self.vendor.filter.nextMatchInLines(self.vendor.query, cursor, self.current_line);
                switch (result) {
                    .match => |match| if (match.match == null) return,
                    .ignore => return,
                }
                const match = result.match;

                const color = if (self.vendor.hl_map.get(match.cap_name)) |color| color else RAY_WHITE;
                const start = @max(match.cap_node.?.getStartByte(), self.line_start_byte) -| self.line_start_byte;
                const end = @min((match.cap_node.?.getEndByte()), self.line_end_byte) -| self.line_start_byte;

                if (start <= end and start <= self.line.?.len and end <= self.line.?.len) {
                    @memset(self.highlights.?[start..end], color);
                }
            }
        }

        pub fn nextChar(self: *@This(), buf: []u8) ?struct { [*:0]u8, u32 } {
            const zone = ztracy.ZoneNC(@src(), "iter.nextChar()", 0x00AAFF);
            defer zone.End();

            if (self.line_byte_offset >= self.line.?.len) {
                self.current_line += 1;
                if (self.current_line > self.end_line) return null;
                self.updateLineContent() catch return null;
                self.updateLineHighlights() catch return null;
                self.line_byte_offset = 0;
            }

            var cp_iter = code_point.Iterator{ .i = @intCast(self.line_byte_offset), .bytes = self.line.? };
            if (cp_iter.next()) |cp| {
                defer self.line_byte_offset += cp.len;
                const char_bytes = self.line.?[self.line_byte_offset .. self.line_byte_offset + cp.len];
                const sentichar = std.fmt.bufPrintZ(buf, "{s}", .{char_bytes}) catch @panic("error calling bufPrintZ");
                const color = self.highlights.?[self.line_byte_offset];
                return .{ sentichar, color };
            }

            return null;
        }

        test CurrentJobIterator {
            { // out of bounds
                const iter = try setupTestIter("const", 0, 100);
                defer teardownTestIer(iter);
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, null, null);
            }
            {
                const iter = try setupTestIter("const Allocator = @import(\"std\").mem.Allocator;", 0, 0);
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
                const iter = try setupTestIter("const a = 10;\nvar not_false = true;", 0, 1);
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
                const iter = try setupTestIter("const a = 10;\nvar not_false = true;", 1, 1);
                defer teardownTestIer(iter);
                try testIter(iter, "var", "type.qualifier");
                try testIter(iter, " not_false = ", "variable");
                try testIter(iter, "true", "boolean");
                try testIter(iter, ";", "punctuation.delimiter");
                try testIter(iter, null, null);
            }
            {
                const iter = try setupTestIter("const\n", 0, 999);
                defer teardownTestIer(iter);
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, null, null);
            }
            {
                const iter = try setupTestIter("const\n\n", 0, 999);
                defer teardownTestIer(iter);
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "\n", "variable");
                try testIter(iter, null, null);
            }
            {
                const iter = try setupTestIter("const\n\nsomething", 0, 999);
                defer teardownTestIer(iter);
                try testIter(iter, "const", "type.qualifier");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "\n", "variable");
                try testIter(iter, "something", "variable");
                try testIter(iter, null, null);
            }
        }
        pub fn testIter(iter: *CurrentJobIterator, expected_sequence: ?[]const u8, expected_group: ?[]const u8) !void {
            if (expected_sequence == null) {
                var buf_: [10]u8 = undefined;
                try eq(null, iter.nextChar(&buf_));
                return;
            }

            var code_point_iter = code_point.Iterator{ .bytes = expected_sequence.? };
            var i: usize = 0;
            while (code_point_iter.next()) |cp| {
                var buf_: [10]u8 = undefined;
                const char, const color = iter.nextChar(&buf_).?;
                const expected_char = expected_sequence.?[cp.offset .. cp.offset + cp.len];
                eqStr(expected_char, std.mem.span(char)) catch {
                    std.debug.print("\n================\n", .{});
                    std.debug.print("Comparison failed on index [{d}] of expected_sequence '{s}'.\n", .{ i, expected_sequence.? });
                    std.debug.print("=================\n", .{});
                    return error.TestExpectedEqual;
                };
                try eq(iter.vendor.hl_map.get(expected_group.?).?, color);
                defer i += 1;
            }
        }
        fn teardownTestIer(iter: *CurrentJobIterator) void {
            iter.vendor.buffer.destroy();
            iter.vendor.deinit();
            iter.deinit();
        }
        fn setupTestIter(source: []const u8, start_line: usize, end_line: usize) !*CurrentJobIterator {
            var buf = try Buffer.create(testing_allocator, .string, source);
            try buf.initiateTreeSitter(.zig);
            const vendor = try ContentVendor.init(testing_allocator, buf);
            const iter = try vendor.requestLines(start_line, end_line);
            return iter;
        }
    };

    pub fn requestLines(self: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
        return try CurrentJobIterator.init(self.a, self, start_line, end_line);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Highlighter = struct {
    a: Allocator,
    buffer: *Buffer,
    query: *ts.Query,
    hl_map: std.StringHashMap(u32),
    filter: *PredicatesFilter,

    pub fn init(a: Allocator, buffer: *Buffer, hl_map: std.StringHashMap(u32), query: *ts.Query) !*@This() {
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

    pub fn deinit(self: *@This()) void {
        self.filter.deinit();
        self.a.destroy(self);
    }

    const Iterator = struct {
        a: Allocator,
        parent: *Highlighter,

        start_line: usize,
        end_line: usize,

        current_line: usize,
        current_line_offset: usize,

        lines: ArrayList([]const u8),
        highlights: ArrayList([]u32),

        pub fn init(parent: *const Highlighter, start_line: usize, end_line: usize) !*Iterator {
            const zone = ztracy.ZoneNC(@src(), "Highlighter.Iterator.init()", 0x00AAFF);
            defer zone.End();

            const self = try parent.a.create(@This());
            self.* = .{
                .a = parent.a,
                .parent = parent,

                .start_line = start_line,
                .end_line = end_line,

                .current_line = start_line,
                .current_line_offset = 0,

                .lines = try ArrayList([]const u8).initCapacity(self.a, end_line - start_line),
                .highlights = try ArrayList([]u32).initCapacity(self.a, end_line - start_line),
            };

            return self;
        }

        pub fn deinit(self: *@This()) !void {
            for (self.lines.items) |line| self.a.free(line);
            for (self.highlights.items) |slice| self.a.free(slice);
            self.lines.deinit();
            self.highlights.deinit();
            self.a.destroy(self);
        }
    };
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDeclsRecursive(ContentVendor);
    std.testing.refAllDeclsRecursive(Highlighter);
}
