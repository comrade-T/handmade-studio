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
    query: ?*Query = null,
    filter: ?*PredicatesFilter = null,
    highlight_map: ?std.StringHashMap(u32) = null,

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
        if (self.highlight_map) |_| self.highlight_map.?.deinit();
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

    pub fn initializeHighlightMap(self: *@This(), a: Allocator) !void {
        var map = std.StringHashMap(u32).init(a);

        try map.put("__blank", rgba(0, 0, 0, 0)); // \n
        try map.put("variable", rgba(245, 245, 245, 245)); // identifier ray_white
        try map.put("type.qualifier", rgba(200, 122, 255, 255)); // const purple
        try map.put("type", rgba(0, 117, 44, 255)); // Allocator dark_green
        try map.put("function.builtin", rgba(0, 121, 241, 255)); // @import blue
        try map.put("include", rgba(230, 41, 55, 255)); // @import red
        try map.put("boolean", rgba(230, 41, 55, 255)); // true red
        try map.put("string", rgba(253, 249, 0, 255)); // "hello" yellow
        try map.put("punctuation.bracket", rgba(255, 161, 0, 255)); // () orange
        try map.put("punctuation.delimiter", rgba(255, 161, 0, 255)); // ; orange
        try map.put("number", rgba(255, 161, 0, 255)); // 12 orange
        try map.put("field", rgba(0, 121, 241, 255)); // std.'mem' blue

        self.highlight_map = map;
    }

    pub fn newParser(self: *@This()) !*Parser {
        var parser = try Parser.create();
        try parser.setLanguage(self.language);
        return parser;
    }
};

fn rgba(red: u32, green: u32, blue: u32, alpha: u32) u32 {
    return red << 24 | green << 16 | blue << 8 | alpha;
}
