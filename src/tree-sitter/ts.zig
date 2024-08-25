const std = @import("std");
pub const b = @import("bindings.zig");
pub const PredicatesFilter = @import("predicates.zig").PredicatesFilter;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Notes

// This file contians tests for the entire 'ts' module.
// It also exposes the Tree Sitter bindings, PredicatesFilter struct and Tarzan struct.

////////////////////////////////////////////////////////////////////////////////////////////// Tests

// TODO:

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

fn setupTest(source: []const u8, patterns: []const u8) !struct { *b.Parser, *b.Tree, *b.Query, *b.Query.Cursor } {
    const ziglang = try b.Language.get("zig");

    var parser = try b.Parser.create();
    try parser.setLanguage(ziglang);

    const tree = try parser.parseString(null, source);
    const query = try b.Query.create(ziglang, patterns);
    const cursor = try b.Query.Cursor.create();
    cursor.execute(query, tree.getRootNode());

    return .{ parser, tree, query, cursor };
}

fn teardownTest(parser: *b.Parser, tree: *b.Tree, query: *b.Query, cursor: *b.Query.Cursor) !void {
    parser.destroy();
    tree.destroy();
    query.destroy();
    cursor.destroy();
}
