const std = @import("std");
const ts = @import("bindings.zig");

test "try ts with Zig" {
    const allocator = std.heap.page_allocator;
    const ziglang = try ts.Language.get("zig");

    var parser = try ts.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(ziglang);

    const source =
        \\const std = @import("std");
        \\const ts = @import("ts")
    ;
    const tree = try parser.parseString(null, source);
    defer tree.destroy();

    const query = try ts.Query.create(ziglang,
        \\(IDENTIFIER) @id
    );
    defer query.destroy();

    var pv = try ts.CursorWithValidation.init(allocator, query);

    const cursor = try ts.Query.Cursor.create();
    defer cursor.destroy();

    cursor.execute(query, tree.getRootNode());

    var i: u16 = 0;
    while (pv.nextCapture(source, cursor)) |capture| {
        const node = capture.node;
        const content = source[node.getStartByte()..node.getEndByte()];
        if (i == 0) try std.testing.expectEqualStrings("std", content);
        if (i == 1) try std.testing.expectEqualStrings("ts", content);
        i += 1;
    }
}
