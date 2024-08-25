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
    lang_choice: SupportedLanguages,
    language: *const Language,
    query: ?*const Query = null,
    filter: ?*PredicatesFilter = null,

    pub fn create(lang_choice: SupportedLanguages) !LangSuite {
        const zone = ztracy.ZoneNC(@src(), "LangSuite.create()", 0xFF00FF);
        defer zone.End();

        const language = switch (lang_choice) {
            .zig => try Language.get("zig"),
        };
        return .{ .lang_choice = lang_choice, .language = language };
    }

    pub fn destroy(self: *@This()) void {
        if (self.query) |query| query.destroy();
        if (self.filter) |filter| filter.deinit();
    }

    pub fn createQuery(self: *@This()) !void {
        const zone = ztracy.ZoneNC(@src(), "LangSuite.createQuery()", 0x00AAFF);
        defer zone.End();

        const patterns = switch (self.lang_choice) {
            .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
        };
        self.query = try b.Query.create(self.language, patterns);
    }

    pub fn initializeFilter(self: *@This(), a: Allocator) !void {
        self.filter = try PredicatesFilter.init(a, self.query.?);
    }

    pub fn newParser(self: *@This()) !*Parser {
        var parser = try Parser.create();
        try parser.setLanguage(self.language);
        return parser;
    }
};
