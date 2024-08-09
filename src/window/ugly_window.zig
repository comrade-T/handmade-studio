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

const Window = struct {
    a: Allocator,

    buffer: *Buffer,

    filter: *PredicatesFilter,

    x: i32 = 0,
    y: i32 = 0,
    width: ?i32 = null,
    height: ?i32 = null,

    pub fn spawn(a: Allocator, buffer: *Buffer, filter: *PredicatesFilter) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .buffer = buffer,
            .filter = filter,
        };
        return self;
    }

    test spawn {
        var buf = try Buffer.create(testing_allocator, .string, "const std = @import(\"std\");");
        try buf.initiateTreeSitter(.zig);
        defer buf.destroy();

        const query = try getTSQuery(.zig);
        const filter = try PredicatesFilter.initWithContentCallback(testing_allocator, query, Buffer.contentCallback, buf);
        defer filter.deinit();

        var win = try Window.spawn(testing_allocator, buf, filter);
        defer win.destroy();

        const cursor = try ts.Query.Cursor.create();
        cursor.execute(query, buf.tstree.?.getRootNode());

        {
            while (filter.nextMatchOnDemand(cursor)) |match| {
                const cap = match.captures()[0];
                const capture_name = query.getCaptureNameForId(cap.id);
                std.debug.print("capture_name: {s}\n", .{capture_name});
                std.debug.print("start_byte: {d} | end_byte: {d}\n", .{ cap.node.getStartByte(), cap.node.getEndByte() });
                std.debug.print("--------------------------------------------------------------\n", .{});
            }
        }
    }

    pub fn destroy(self: *@This()) void {
        self.a.destroy(self);
    }
};

test {
    std.testing.refAllDecls(Window);
}
