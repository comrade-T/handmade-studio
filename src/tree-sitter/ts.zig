const std = @import("std");
const b = @import("bindings.zig");
const PredicatesFilter = @import("predicates.zig").PredicatesFilter;

// test "try ts with Zig" {
//     const a = std.testing.allocator;
//     const ziglang = try b.Language.get("zig");
//
//     var parser = try b.Parser.create();
//     defer parser.destroy();
//
//     try parser.setLanguage(ziglang);
//
//     const source =
//         \\const std = @import("std");
//         \\const ts = @import("ts")
//     ;
//     const tree = try parser.parseString(null, source);
//     defer tree.destroy();
//
//     const query = try b.Query.create(ziglang,
//         \\(IDENTIFIER) @id
//     );
//     defer query.destroy();
//
//     var pv = try CursorWithValidation.init(a, query);
//     defer pv.deinit();
//
//     const cursor = try b.Query.Cursor.create();
//     defer cursor.destroy();
//
//     cursor.execute(query, tree.getRootNode());
//
//     var i: u16 = 0;
//     while (pv.nextCapture(source, cursor)) |capture| {
//         const node = capture.node;
//         const content = source[node.getStartByte()..node.getEndByte()];
//         if (i == 0) try std.testing.expectEqualStrings("std", content);
//         if (i == 1) try std.testing.expectEqualStrings("ts", content);
//         i += 1;
//     }
// }

const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

fn getTreeForTesting(source: []const u8, patterns: []const u8) !struct { *b.Tree, *b.Query, *b.Query.Cursor } {
    const ziglang = try b.Language.get("zig");

    var parser = try b.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ziglang);

    const tree = try parser.parseString(null, source);
    const query = try b.Query.create(ziglang, patterns);
    const cursor = try b.Query.Cursor.create();
    cursor.execute(query, tree.getRootNode());

    return .{ tree, query, cursor };
}

test PredicatesFilter {
    const a = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\const raylib = @cImport({
        \\    @cInclude("raylib.h");
        \\});
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
    ;

    const tree, const query, const cursor = try getTreeForTesting(source, patterns);
    defer tree.destroy();
    defer query.destroy();
    defer cursor.destroy();

    var filter = try PredicatesFilter.init(a, query);
    defer filter.deinit();

    {
        try eq(3, filter.patterns.len);

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
            try eq(null, filter.nextMatch(source, cursor));
        }
    }
}
