const std = @import("std");
const _neo_buffer = @import("neo_buffer");
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

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const HighlightMap = enum(Color) {
        variable = Color.init(245, 245, 245, 255),
    };

    const CurrentJobIterator = struct {
        const BUF_SIZE = 1024;

        a: Allocator,
        vendor: *ContentVendor,
        cursor: *ts.Query.Cursor,

        content: std.ArrayList(u8),
        start_row: usize = 0,
        end_row: usize = 0,
        current_row: usize = 0,
        current_col: usize = 0,

        pub fn init(a: Allocator, vendor: *ContentVendor) !*CurrentJobIterator {
            const self = try a.create(@This());
            self.* = .{
                .a = a,
                .vendor = vendor,
                .cursor = try ts.Query.Cursor.create(),
                .content = std.ArrayList(u8).init(a),
            };
            self.cursor.execute(vendor.query, vendor.buffer.tstree.?.getRootNode());
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.content.deinit();
            self.a.destroy(self);
        }

        pub fn nextChar(self: *@This()) !struct { [*:0]u8, Color } {
            if (self.current_col >= self.content.len) {
                self.content.deinit();
                self.content = try self.vendor.buffer.roperoot.getLine(self.a, self.current_row);
                self.current_col = 0;
            }
        }
        test nextChar {
            // TODO:
        }
    };

    pub fn requestLines(a: Allocator, self: *ContentVendor, start_line: usize, end_line: usize) CurrentJobIterator {
        return try CurrentJobIterator.init(a, self, start_line, end_line);
    }
};

test "experiment" {
    var buf = try Buffer.create(testing_allocator, .string, "const Allocator = @import(\"std\").mem.Allocator;");
    try buf.initiateTreeSitter(.zig);
    defer buf.destroy();

    const vendor = try ContentVendor.init(testing_allocator, buf);
    defer vendor.deinit();

    const cursor = try ts.Query.Cursor.create();
    cursor.execute(vendor.query, buf.tstree.?.getRootNode());

    {
        while (vendor.filter.nextMatchOnDemand(cursor)) |match| {
            const cap = match.captures()[0];
            const capture_name = vendor.query.getCaptureNameForId(cap.id);
            std.debug.print("capture_name: {s}\n", .{capture_name});
            std.debug.print("start_byte: {d} | end_byte: {d}\n", .{ cap.node.getStartByte(), cap.node.getEndByte() });
            var mybuf: [1024]u8 = undefined;
            const content = try buf.roperoot.getRange(cap.node.getStartByte(), cap.node.getEndByte(), &mybuf, 1024);
            std.debug.print("content {s}\n", .{content});
            std.debug.print("---------------------------------------------------------------\n", .{});
        }
    }
}

test {
    std.testing.refAllDecls(ContentVendor);
}
