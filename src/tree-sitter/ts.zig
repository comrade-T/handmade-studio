const std = @import("std");
const ztracy = @import("ztracy");
pub const b = @import("bindings.zig");
pub const PredicatesFilter = @import("predicates.zig").PredicatesFilter;

const Language = b.Language;
const Query = b.Query;
const Parser = b.Parser;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const SupportedLanguages = enum { zig };

pub const LangSuite = struct {
    language: *const Language,
    query: ?*const Query,

    pub fn create(choice: SupportedLanguages, with_query: bool) !LangSuite {
        var language: *const b.Language = undefined;
        {
            const zone = ztracy.ZoneNC(@src(), "ts.Language.get()", 0xFF00FF);
            defer zone.End();

            language = switch (choice) {
                .zig => try Language.get("zig"),
            };
        }

        var query: ?*const b.Query = null;
        if (with_query) {
            const zone = ztracy.ZoneNC(@src(), "ts.Query.create()", 0x00AAFF);
            defer zone.End();

            const patterns = switch (choice) {
                .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
            };
            query = try b.Query.create(language, patterns);
        }

        return .{ .language = language, .query = query };
    }

    pub fn destroy(self: *@This()) void {
        self.query.destroy();
    }

    pub fn newParser(self: *@This()) !*Parser {
        var parser = try Parser.create();
        try parser.setLanguage(self.language);
        return parser;
    }
};
