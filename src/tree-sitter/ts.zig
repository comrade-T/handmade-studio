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

fn testInputEdit(
    old_source: []const u8,
    patterns: []const u8,
    old_expect: ?[]const u8,
    edit: b.InputEdit,
    new_source: []const u8,
    new_expect: ?[]const u8,
) !void {
    ///////////////////////////// old tree

    const a = std.testing.allocator;

    const parser, const old_tree, const query, const cursor = try getTreeForTesting(old_source, patterns);
    defer parser.destroy();
    defer old_tree.destroy();
    defer query.destroy();
    defer cursor.destroy();

    var filter = try PredicatesFilter.init(a, query);
    defer filter.deinit();

    {
        const result = filter.nextMatch(old_source, cursor);
        if (old_expect) |expected| {
            const node = result.?.captures()[0].node;
            try eqStr(expected, old_source[node.getStartByte()..node.getEndByte()]);
        } else {
            try eq(null, result);
        }
    }

    ///////////////////////////// new tree

    old_tree.edit(&edit);
    try eq(true, old_tree.getRootNode().hasChanges());

    const new_tree = try parser.parseString(old_tree, new_source);
    defer new_tree.destroy();
    const new_cursor = try b.Query.Cursor.create();
    new_cursor.execute(query, new_tree.getRootNode());

    {
        const result = filter.nextMatch(new_source, new_cursor);
        if (new_expect) |expected| {
            const node = result.?.captures()[0].node;
            try eqStr(expected, new_source[node.getStartByte()..node.getEndByte()]);
        } else {
            try eq(null, result);
        }
    }
}

test "InputEdit" {
    const source =
        \\const std = @import("std");
    ;
    const patterns =
        \\((IDENTIFIER) @identifier
        \\  (#any-of? @identifier "std" "hello"))
    ;
    const new_source =
        \\const hello = @import("std");
    ;
    const edit = b.InputEdit{
        .start_byte = 7,
        .old_end_byte = 9,
        .new_end_byte = 11,
        .start_point = b.Point{ .row = 0, .column = 7 },
        .old_end_point = b.Point{ .row = 0, .column = 9 },
        .new_end_point = b.Point{ .row = 0, .column = 11 },
    };
    try testInputEdit(source, patterns, "std", edit, new_source, "hello");
}

test "InputEdit_insert_char" {
    const old_source =
        \\const = @import("std");
    ;
    const patterns =
        \\((IDENTIFIER) @identifier
        \\  (#any-of? @identifier "std" "hello"))
    ;
    const edit = b.InputEdit{
        .start_byte = 6,
        .old_end_byte = 6,
        .new_end_byte = 11,
        .start_point = b.Point{ .row = 0, .column = 6 },
        .old_end_point = b.Point{ .row = 0, .column = 6 },
        .new_end_point = b.Point{ .row = 0, .column = 11 },
    };
    const new_source =
        \\const hello = @import("std");
    ;
    try testInputEdit(old_source, patterns, null, edit, new_source, "hello");
}

test "InputEdit_delete_char_backwards" {
    const old_source =
        \\const mystd
    ;
    const patterns =
        \\((IDENTIFIER) @identifier
        \\  (#any-of? @identifier "std" "s"))
    ;
    const edit = b.InputEdit{
        .start_byte = 0,
        .old_end_byte = 0,
        .new_end_byte = 8,
        .start_point = b.Point{ .row = 0, .column = 0 },
        .old_end_point = b.Point{ .row = 0, .column = 0 },
        .new_end_point = b.Point{ .row = 0, .column = 8 },
    };
    const new_source = "std";
    try testInputEdit(old_source, patterns, null, edit, new_source, "std");
}

//////////////////////////////////////////////////////////////////////////////////////////////

test "InputEdit_NEW" {
    const ziglang = try b.Language.get("zig");
    var parser = try b.Parser.create();
    try parser.setLanguage(ziglang);

    var state: usize = 0;
    const input: b.Input = .{
        .payload = &state,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, position: b.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                const ctx: *usize = @ptrCast(@alignCast(payload orelse return ""));
                defer ctx.* += 1;

                std.debug.print("requesting {any}\n", .{position});

                const result = switch (ctx.*) {
                    // 0 => "const std = @import(\"std\");",
                    0 => "const",
                    1 => " std ",
                    2 => "= ",
                    3 => "@import(\"std\");",
                    else => "",
                };

                bytes_read.* = @intCast(result.len);
                return result;
            }
        }.read,
        .encoding = .utf_8,
    };

    const tree = try parser.parse(null, input);
    std.debug.print("{s}\n", .{try tree.getRootNode().debugPrint()});
}
