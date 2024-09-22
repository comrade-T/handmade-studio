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

pub const DEFAULT_QUERIES_NAME = "DEFAULT";

pub const StoredQuery = struct {
    query: *b.Query,
    patterns: []const u8,
};

pub const LangSuite = struct {
    lang_choice: SupportedLanguages,
    language: *const Language,

    queries: ?std.StringArrayHashMap(*StoredQuery) = null,
    queries_arena: ?std.heap.ArenaAllocator = null,

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
        if (self.queries_arena) |_| self.queries_arena.?.deinit();
        if (self.filter) |filter| filter.deinit();
        if (self.highlight_map) |_| self.highlight_map.?.deinit();
    }

    pub fn initializeQueryMap(self: *@This()) !void {
        const zone = ztracy.ZoneNC(@src(), "LangSuite.initializeDefaultQuery()", 0x00AAFF);
        defer zone.End();

        const patterns = switch (self.lang_choice) {
            .zig => @embedFile("submodules/tree-sitter-zig/queries/highlights.scm"),
        };

        self.queries_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.queries = std.StringArrayHashMap(*StoredQuery).init(self.queries_arena.?.allocator());
        try self.addQuery(DEFAULT_QUERIES_NAME, patterns);
    }

    pub fn addQuery(self: *@This(), id: []const u8, patterns: []const u8) !void {
        const query = try b.Query.create(self.language, patterns);
        if (self.queries) |_| {
            const sq = try self.queries_arena.?.allocator().create(StoredQuery);
            sq.* = StoredQuery{
                .query = query,
                .patterns = try self.queries_arena.?.allocator().dupe(u8, patterns),
            };
            try self.queries.?.put(id, sq);
        }
    }

    pub fn initializeNightflyColorscheme(self: *@This(), a: Allocator) !void {
        var map = std.StringHashMap(u32).init(a);

        try map.put("keyword", @intFromEnum(Nightfly.violet));
        try map.put("keyword.modifier", @intFromEnum(Nightfly.violet));
        try map.put("keyword.function", @intFromEnum(Nightfly.violet));
        try map.put("attribute", @intFromEnum(Nightfly.violet));
        try map.put("type.qualifier", @intFromEnum(Nightfly.violet));

        try map.put("type", @intFromEnum(Nightfly.emerald));
        try map.put("type.builtin", @intFromEnum(Nightfly.emerald));

        try map.put("function", @intFromEnum(Nightfly.blue));
        try map.put("function.builtin", @intFromEnum(Nightfly.blue));
        try map.put("field", @intFromEnum(Nightfly.lavender));
        try map.put("string", @intFromEnum(Nightfly.peach));
        try map.put("comment", @intFromEnum(Nightfly.grey_blue));
        try map.put("constant.builtin", @intFromEnum(Nightfly.green));

        try map.put("boolean", @intFromEnum(Nightfly.watermelon));
        try map.put("operator", @intFromEnum(Nightfly.watermelon));
        try map.put("number", @intFromEnum(Nightfly.orange));

        try map.put("variable", @intFromEnum(Nightfly.white));
        try map.put("punctuation.bracket", @intFromEnum(Nightfly.white));
        try map.put("punctuation.delimiter", @intFromEnum(Nightfly.white));

        self.highlight_map = map;
    }

    pub fn newParser(self: *@This()) !*Parser {
        var parser = try Parser.create();
        try parser.setLanguage(self.language);
        return parser;
    }
};

const Nightfly = enum(u32) {
    none = 0x000000ff,
    black = 0x011627ff,
    white = 0xc3ccdcff,
    black_blue = 0x081e2fff,
    dark_blue = 0x092236ff,
    deep_blue = 0x0e293fff,
    slate_blue = 0x2c3043ff,
    pickle_blue = 0x38507aff,
    cello_blue = 0x1f4462ff,
    regal_blue = 0x1d3b53ff,
    steel_blue = 0x4b6479ff,
    grey_blue = 0x7c8f8fff,
    cadet_blue = 0xa1aab8ff,
    ash_blue = 0xacb4c2ff,
    white_blue = 0xd6deebff,
    yellow = 0xe3d18aff,
    peach = 0xffcb8bff,
    tan = 0xecc48dff,
    orange = 0xf78c6cff,
    orchid = 0xe39aa6ff,
    red = 0xfc514eff,
    watermelon = 0xff5874ff,
    purple = 0xae81ffff,
    violet = 0xc792eaff,
    lavender = 0xb0b2f4ff,
    blue = 0x82aaffff,
    malibu = 0x87bcffff,
    turquoise = 0x7fdbcaff,
    emerald = 0x21c7a8ff,
    green = 0xa1cd5eff,
    cyan_blue = 0x296596ff,
    bay_blue = 0x24567fff,
    kashmir_blue = 0x4d618eff,
    plant_green = 0x2a4e57ff,
};

fn rgba(red: u32, green: u32, blue: u32, alpha: u32) u32 {
    return red << 24 | green << 16 | blue << 8 | alpha;
}
