const std = @import("std");
pub const b = @import("bindings.zig");
pub const PredicatesFilter = @import("predicates.zig").PredicatesFilter;

const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

fn getTreeForTesting(source: []const u8, patterns: []const u8) !struct { *b.Parser, *b.Tree, *b.Query, *b.Query.Cursor } {
    const ziglang = try b.Language.get("zig");

    var parser = try b.Parser.create();
    try parser.setLanguage(ziglang);

    const tree = try parser.parseString(null, source);
    const query = try b.Query.create(ziglang, patterns);
    const cursor = try b.Query.Cursor.create();
    cursor.execute(query, tree.getRootNode());

    return .{ parser, tree, query, cursor };
}

test PredicatesFilter {
    const a = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\const raylib = @cImport({
        \\    @cInclude("raylib.h");
        \\});
        \\
        \\const StandardAllocator = standard.mem.Allocator;
    ;
    const patterns =
        \\((IDENTIFIER) @std_identifier
        \\  (#eq? @std_identifier "std"))
        \\
        \\((BUILTINIDENTIFIER) @include
        \\  (#any-of? @include "@import" "@cImport"))
        \\
        \\((IDENTIFIER) @contrived-example
        \\  (#eq? @contrived-example "@contrived")
        \\  (#contrived-predicate? @contrived-example "contrived-argument"))
        \\
        \\;; assume TitleCase is a type
        \\(
        \\  [
        \\    variable_type_function: (IDENTIFIER)
        \\    field_access: (IDENTIFIER)
        \\    parameter: (IDENTIFIER)
        \\  ] @type
        \\  (#match? @type "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
        \\)
    ;

    // Experimental
    {
        const parser, const tree, const query, const cursor = try getTreeForTesting(source, patterns);
        defer parser.destroy();
        defer tree.destroy();
        defer query.destroy();
        defer cursor.destroy();

        const MyStruct = struct {
            a: std.mem.Allocator,
            value: usize,

            fn create(allocator: std.mem.Allocator, value: usize) !*@This() {
                var self = try allocator.create(@This());
                self.a = allocator;
                self.value = value;
                return self;
            }

            fn destroy(self: *@This()) void {
                self.a.destroy(self);
            }

            fn callback(ctx_: *anyopaque, start_byte: usize, end_byte: usize) []u8 {
                const ctx: *@This() = @ptrCast(@alignCast(ctx_));
                std.debug.print("ctx.myfield: {d}\n", .{ctx.value});
                std.debug.print("start_byte: {d} | end_byte: {d}\n", .{ start_byte, end_byte });
                return "";
            }
        };

        const my_instance = try MyStruct.create(a, 100);
        defer my_instance.destroy();
        var filter = try PredicatesFilter.initWithContentCallback(a, query, MyStruct.callback, my_instance);
        defer filter.deinit();

        const result = filter.nextMatchOnDemand(cursor);
        _ = result;
    }

    // Old Tests
    {
        const parser, const tree, const query, const cursor = try getTreeForTesting(source, patterns);
        defer parser.destroy();
        defer tree.destroy();
        defer query.destroy();
        defer cursor.destroy();

        var filter = try PredicatesFilter.init(a, query);
        defer filter.deinit();

        {
            try eq(4, filter.patterns.len);

            try eq(1, filter.patterns[0].len);
            try eqStr("std_identifier", filter.patterns[0][0].eq.capture);
            try eqStr("std", filter.patterns[0][0].eq.target);

            try eq(1, filter.patterns[1].len);
            try eqStr("include", filter.patterns[1][0].any_of.capture);
            try eq(2, filter.patterns[1][0].any_of.targets.len);
            try eqStr("@import", filter.patterns[1][0].any_of.targets[0]);
            try eqStr("@cImport", filter.patterns[1][0].any_of.targets[1]);

            try eq(2, filter.patterns[2].len);
            try eqStr("contrived-example", filter.patterns[2][0].eq.capture);
            try eqStr("@contrived", filter.patterns[2][0].eq.target);
            try eq(.unsupported, filter.patterns[2][1].unsupported);

            try eq(1, filter.patterns[3].len);
            try eqStr("type", filter.patterns[3][0].match.capture);
            try eqStr("^[A-Z]([a-z]+[A-Za-z0-9]*)*$", filter.patterns[3][0].match.regex_pattern);
        }

        {
            {
                const result = filter.nextMatch(source, cursor);
                const node = result.?.captures()[0].node;
                try eq(1, result.?.captures_len);
                try eqStr("std", source[node.getStartByte()..node.getEndByte()]);
            }

            {
                const result = filter.nextMatch(source, cursor);
                const node = result.?.captures()[0].node;
                try eq(1, result.?.captures_len);
                try eqStr("@import", source[node.getStartByte()..node.getEndByte()]);
            }

            {
                const result = filter.nextMatch(source, cursor);
                const node = result.?.captures()[0].node;
                try eq(1, result.?.captures_len);
                try eqStr("@cImport", source[node.getStartByte()..node.getEndByte()]);
            }

            {
                const result = filter.nextMatch(source, cursor);
                const node = result.?.captures()[0].node;
                try eq(1, result.?.captures_len);
                try eqStr("StandardAllocator", source[node.getStartByte()..node.getEndByte()]);
            }

            {
                const result = filter.nextMatch(source, cursor);
                const node = result.?.captures()[0].node;
                try eq(1, result.?.captures_len);
                try eqStr("Allocator", source[node.getStartByte()..node.getEndByte()]);
            }

            {
                try eq(null, filter.nextMatch(source, cursor));
            }
        }
    }
}
