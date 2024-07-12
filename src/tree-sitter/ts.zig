const std = @import("std");
const b = @import("bindings.zig");
const CursorWithValidation = @import("predicates.zig").CursorWithValidation;

test "try ts with Zig" {
    const a = std.testing.allocator;
    const ziglang = try b.Language.get("zig");

    var parser = try b.Parser.create();
    defer parser.destroy();

    try parser.setLanguage(ziglang);

    const source =
        \\const std = @import("std");
        \\const ts = @import("ts")
    ;
    const tree = try parser.parseString(null, source);
    defer tree.destroy();

    const query = try b.Query.create(ziglang,
        \\(IDENTIFIER) @id
    );
    defer query.destroy();

    var pv = try CursorWithValidation.init(a, query);
    defer pv.deinit();

    const cursor = try b.Query.Cursor.create();
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
