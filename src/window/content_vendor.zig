const std = @import("std");
const _neo_buffer = @import("neo_buffer");
const code_point = _neo_buffer.code_point;
const ts = _neo_buffer.ts;
const Buffer = _neo_buffer.Buffer;
const PredicatesFilter = _neo_buffer.PredicatesFilter;
const SupportedLanguages = _neo_buffer.SupportedLanguages;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

fn getTSQuery(lang: SupportedLanguages) !*ts.Query {
    const tslang = switch (lang) {
        .zig => try ts.Language.get("zig"),
    };
    const patterns = switch (lang) {
        .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
    };
    const query = try ts.Query.create(tslang, patterns);
    return query;
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return r << 24 | g << 16 | b << 8 | a;
}

const RAY_WHITE = rgba(245, 245, 245, 245);

fn createHighlightMap(a: Allocator) !std.StringHashMap(u32) {
    var map = std.StringHashMap(u32).init(a);
    try map.put("variable", rgba(245, 245, 245, 245)); // identifier ray_white
    try map.put("type.qualifier", rgba(200, 122, 255, 255)); // const purple
    try map.put("type", rgba(0, 117, 44, 255)); // Allocator dark_green
    try map.put("function.builtin", rgba(0, 121, 241, 255)); // @import blue
    try map.put("include", rgba(230, 41, 55, 255)); // @import red
    try map.put("string", rgba(253, 249, 0, 255)); // "hello" yellow
    try map.put("punctuation.bracket", rgba(255, 161, 0, 255)); // () orange
    try map.put("punctuation.delimiter", rgba(255, 161, 0, 255)); // ; orange
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

    const CurrentJobIterator = struct {
        const BUF_SIZE = 1024;

        a: Allocator,
        vendor: *ContentVendor,

        start_line: usize,
        end_line: usize,
        current_line: usize,

        line: std.ArrayList(u8),
        line_byte_offset: usize,
        line_start_byte: u32, // (relative to document)
        line_end_byte: u32, // (relative to document)

        highlights: ?[]u32,

        pub fn init(a: Allocator, vendor: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
            const self = try a.create(@This());
            self.* = .{
                .a = a,
                .vendor = vendor,

                .start_line = start_line,
                .end_line = end_line,
                .current_line = start_line,

                .line = std.ArrayList(u8).init(a),
                .line_byte_offset = 0,
                .line_start_byte = 0,
                .line_end_byte = 0,

                .highlights = null,
            };
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.line.deinit();
            if (self.highlights) |highlights| self.a.free(highlights);
            self.a.destroy(self);
        }

        fn updateLineContent(self: *@This()) !void {
            self.line.deinit();
            self.line, const line_start_byte, _ = try self.vendor.buffer.roperoot.getLine(self.a, self.current_line);
            const line_end_byte = self.line_start_byte + self.line.items.len;
            self.line_start_byte = @intCast(line_start_byte);
            self.line_end_byte = @intCast(line_end_byte);
            self.line_byte_offset = 0;
        }

        fn updateLineHighlights(self: *@This()) !void {
            if (self.highlights) |highlights| self.a.free(highlights);
            self.highlights = try self.a.alloc(u32, self.line.items.len);
            @memset(self.highlights.?, DEFAULT_COLOR);

            const cursor = try ts.Query.Cursor.create();
            defer cursor.destroy();
            cursor.execute(self.vendor.query, self.vendor.buffer.tstree.?.getRootNode());

            while (self.vendor.filter.nextMatchInLines(cursor, self.start_line, self.end_line)) |match| {
                const cap = match.captures()[0];
                const capture_name = self.vendor.query.getCaptureNameForId(cap.id);
                const color = if (self.vendor.hl_map.get(capture_name)) |color| color else RAY_WHITE;

                const start = @max(cap.node.getStartByte(), self.line_start_byte) - self.line_start_byte;
                const end = @min((cap.node.getEndByte()), self.line_end_byte) - self.line_start_byte;
                @memset(self.highlights.?[start..end], color);

                // std.debug.print("capture_name: {s} | start: {d} | end: {d} | hl_group {any}\n", .{ capture_name, start, end, hl_group });
            }
        }

        pub fn nextChar(self: *@This(), buf: []u8) ?struct { [*:0]u8, u32 } {
            if (self.line_byte_offset >= self.line.items.len) {
                self.updateLineContent() catch return null;
                self.updateLineHighlights() catch return null;
            }

            var cp_iter = code_point.Iterator{ .i = @intCast(self.line_byte_offset), .bytes = self.line.items };
            if (cp_iter.next()) |cp| {
                defer self.line_byte_offset += cp.len;
                const char_bytes = self.line.items[self.line_byte_offset .. self.line_byte_offset + cp.len];
                const sentichar = std.fmt.bufPrintZ(buf, "{s}", .{char_bytes}) catch @panic("error calling bufPrintZ");
                const color = self.highlights.?[self.line_byte_offset];
                return .{ sentichar, color };
            }

            return null;
        }
        test nextChar {
            var buf = try Buffer.create(testing_allocator, .string, "const Allocator = @import(\"std\").mem.Allocator;");
            try buf.initiateTreeSitter(.zig);
            defer buf.destroy();
            const vendor = try ContentVendor.init(testing_allocator, buf);
            defer vendor.deinit();

            var iter = try vendor.requestLines(0, 0);
            defer iter.deinit();
            try testNextChar(iter, "c", "type.qualifier");
            try testNextChar(iter, "o", "type.qualifier");
            try testNextChar(iter, "n", "type.qualifier");
            try testNextChar(iter, "s", "type.qualifier");
            try testNextChar(iter, "t", "type.qualifier");
            try testNextChar(iter, " ", "variable");
        }
        fn testNextChar(iter: *CurrentJobIterator, expected_char: []const u8, expected_group: []const u8) !void {
            var buf_: [10]u8 = undefined;
            const char, const color = iter.nextChar(&buf_).?;
            try eqStr(expected_char, std.mem.span(char));
            try eq(iter.vendor.hl_map.get(expected_group).?, color);
        }
    };

    pub fn requestLines(self: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
        return try CurrentJobIterator.init(self.a, self, start_line, end_line);
    }
};

test {
    std.testing.refAllDecls(ContentVendor);
}
