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

pub const ContentVendor = struct {
    a: Allocator,
    buffer: *Buffer,
    query: *ts.Query,
    filter: *PredicatesFilter,

    pub fn init(a: Allocator, buffer: *Buffer) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .buffer = buffer,
            .query = try getTSQuery(buffer.lang.?),
            .filter = try PredicatesFilter.initWithContentCallback(a, self.query, Buffer.contentCallback, self.buffer),
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.query.destroy();
        self.filter.deinit();
        self.a.destroy(self);
    }

    ///////////////////////////// Job

    fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
        return r << 24 | g << 16 | b << 8 | a;
    }

    const DEFAULT_COLOR = rgba(245, 245, 245, 245);

    const HighlightMap = enum(u32) {
        variable = rgba(245, 245, 245, 245),
        @"type.qualifier" = rgba(230, 41, 55, 255),
    };

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
            for (0..self.highlights.?.len) |i| self.highlights.?[i] = DEFAULT_COLOR;

            const cursor = try ts.Query.Cursor.create();
            defer cursor.destroy();
            cursor.execute(self.vendor.query, self.vendor.buffer.tstree.?.getRootNode());

            while (self.vendor.filter.nextMatchInLines(cursor, self.start_line, self.end_line)) |match| {
                const cap = match.captures()[0];
                const capture_name = self.vendor.query.getCaptureNameForId(cap.id);
                const hl_group = if (std.meta.stringToEnum(HighlightMap, capture_name)) |group| group else HighlightMap.variable;
                const color = @intFromEnum(hl_group);

                const start = @max(cap.node.getStartByte(), self.line_start_byte) - self.line_start_byte;
                const end = @max((cap.node.getEndByte()), self.line_end_byte) - self.line_start_byte;
                for (start..end) |i| self.highlights.?[i] = color;
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
            {
                var buf_: [10]u8 = undefined;
                const char, const color = iter.nextChar(&buf_).?;
                try eqStr("c", std.mem.span(char));
                try eq(@intFromEnum(HighlightMap.@"type.qualifier"), color);
            }
        }
    };

    pub fn requestLines(self: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
        return try CurrentJobIterator.init(self.a, self, start_line, end_line);
    }
};

// test "experiment" {
//     var buf = try Buffer.create(testing_allocator, .string, "const Allocator = @import(\"std\").mem.Allocator;");
//     try buf.initiateTreeSitter(.zig);
//     defer buf.destroy();
//
//     const vendor = try ContentVendor.init(testing_allocator, buf);
//     defer vendor.deinit();
//
//     const cursor = try ts.Query.Cursor.create();
//     cursor.execute(vendor.query, buf.tstree.?.getRootNode());
//
//     {
//         while (vendor.filter.nextMatchOnDemand(cursor)) |match| {
//             const cap = match.captures()[0];
//             const capture_name = vendor.query.getCaptureNameForId(cap.id);
//             std.debug.print("capture_name: {s}\n", .{capture_name});
//             std.debug.print("start_byte: {d} | end_byte: {d}\n", .{ cap.node.getStartByte(), cap.node.getEndByte() });
//             var mybuf: [1024]u8 = undefined;
//             const content = try buf.roperoot.getRange(cap.node.getStartByte(), cap.node.getEndByte(), &mybuf, 1024);
//             std.debug.print("content {s}\n", .{content});
//             std.debug.print("---------------------------------------------------------------\n", .{});
//         }
//     }
// }

test {
    std.testing.refAllDecls(ContentVendor);
}
