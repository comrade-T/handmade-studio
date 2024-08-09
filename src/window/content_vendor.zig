const std = @import("std");
const _neo_buffer = @import("neo_buffer");
const ts = _neo_buffer.ts;
const Buffer = _neo_buffer.Buffer;
const PredicatesFilter = _neo_buffer.PredicatesFilter;
const SupportedLanguages = _neo_buffer.SupportedLanguages;

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

const ContentVendor = struct {
    a: Allocator,
    buffer: *Buffer,
    query: *ts.Query,
    filter: *PredicatesFilter,

    fn init(a: Allocator, buffer: *Buffer) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .buffer = buffer,
            .query = try getTSQuery(buffer.lang.?),
            .filter = try PredicatesFilter.initWithContentCallback(a, self.query, Buffer.contentCallback, self.buffer),
        };
        return self;
    }

    fn deinit(self: *@This()) void {
        self.query.destroy();
        self.filter.deinit();
        self.a.destroy(self);
    }

    fn requestLines() !void {
        // TODO:
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
