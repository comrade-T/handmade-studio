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

    const HighlightMap = enum(u32) {
        variable = rgba(245, 245, 245, 245),
        @"type.qualifier" = rgba(230, 41, 55, 255),
    };

    const CurrentJobIterator = struct {
        const BUF_SIZE = 1024;

        a: Allocator,
        vendor: *ContentVendor,
        cursor: *ts.Query.Cursor,

        start_line: usize,
        end_line: usize,
        current_line: usize,

        line: std.ArrayList(u8),
        line_byte_offset: usize,

        pub fn init(a: Allocator, vendor: *ContentVendor, start_line: usize, end_line: usize) !*CurrentJobIterator {
            const self = try a.create(@This());
            self.* = .{
                .a = a,
                .vendor = vendor,
                .cursor = try ts.Query.Cursor.create(),

                .start_line = start_line,
                .end_line = end_line,
                .current_line = start_line,

                .line = std.ArrayList(u8).init(a),
                .line_byte_offset = 0,
            };
            self.cursor.execute(vendor.query, vendor.buffer.tstree.?.getRootNode());
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.line.deinit();
            self.a.destroy(self);
        }

        pub fn nextChar(self: *@This(), buf: []u8) ?struct { [*:0]u8, u32 } {
            if (self.line_byte_offset >= self.line.items.len) {
                self.line.deinit();
                self.line, _ = self.vendor.buffer.roperoot.getLine(self.a, self.current_line) catch return null;
                self.line_byte_offset = 0;
            }

            var cp_iter = code_point.Iterator{ .i = @intCast(self.line_byte_offset), .bytes = self.line.items };
            if (cp_iter.next()) |cp| {
                const char = self.line.items[self.line_byte_offset .. self.line_byte_offset + cp.len];
                const result = std.fmt.bufPrintZ(buf, "{s}", .{char}) catch @panic("error calling bufPrintZ");
                self.line_byte_offset += cp.len;
                return .{ result, @intFromEnum(HighlightMap.variable) };
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
                _ = color;
                // try eq(@intFromEnum(HighlightMap.@"type.qualifier"), color);
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
