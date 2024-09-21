// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
const ztracy = @import("ztracy");

const Regex = @import("regex").Regex;

const b = @import("bindings.zig");
const Query = b.Query;
const PredicateStep = b.Query.PredicateStep;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const PredicatesFilter = struct {
    external_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    patterns: [][]Predicate = undefined,
    directives: std.AutoArrayHashMap(usize, []Directive),

    const F = *const fn (ctx: *anyopaque, start_byte: usize, end_byte: usize, buf: []u8, buf_size: usize) []const u8;

    pub fn init(external_allocator: Allocator, query: *const Query) !*@This() {
        const zone = ztracy.ZoneNC(@src(), "PredicatesFilter.init()", 0x00AA00);
        defer zone.End();

        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .directives = std.AutoArrayHashMap(usize, []Directive).init(self.arena.allocator()),
        };

        var patterns = std.ArrayList([]Predicate).init(self.arena.allocator());
        errdefer self.arena.deinit();

        for (0..query.getPatternCount()) |pattern_index| {
            const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));

            var predicates = ArrayList(Predicate).init(self.arena.allocator());
            errdefer predicates.deinit();

            var directives = ArrayList(Directive).init(self.arena.allocator());
            errdefer directives.deinit();

            var start: usize = 0;
            for (steps, 0..) |step, i| {
                if (step.type == .done) {
                    defer start = i + 1;
                    const subset = steps[start .. i + 1];
                    const name = checkFirstAndLastSteps(query, subset) catch continue;
                    if (name.len == 0) continue;
                    if (name[name.len - 1] == '?') {
                        const predicate = try Predicate.create(self.arena.allocator(), query, name, steps[start .. i + 1]);
                        if (predicate != .unsupported) try predicates.append(predicate);
                        continue;
                    }
                    if (name[name.len - 1] == '!') {
                        const directive = Directive.create(name, query, subset) catch continue;
                        try directives.append(directive);
                    }
                }
            }

            try patterns.append(try predicates.toOwnedSlice());

            if (directives.items.len == 0) directives.deinit();
            try self.directives.put(pattern_index, try directives.toOwnedSlice());
        }

        self.*.patterns = try patterns.toOwnedSlice();
        return self;
    }

    fn checkFirstAndLastSteps(query: *const Query, subset: []const PredicateStep) PredicateError![]const u8 {
        if (subset[0].type != .string) {
            std.log.err("First step of predicate isn't .string.", .{});
            return PredicateError.Unknown;
        }
        const name = query.getStringValueForId(@as(u32, @intCast(subset[0].value_id)));
        if (subset[subset.len - 1].type != .done) {
            std.log.err("Last step of predicate '{s}' isn't .done.", .{name});
            return PredicateError.InvalidArgument;
        }
        return name;
    }

    fn checkBodySteps(name: []const u8, subset: []const PredicateStep, types: []const PredicateStep.Type) PredicateError!void {
        if (subset.len -| types.len != 2) return PredicateError.InvalidAmountOfSteps;
        for (types, 0..) |t, i| {
            if (subset[i + 1].type != t) {
                std.log.err("Argument #{d} of '{s}' must be type '{any}, not '{any}'", .{
                    i,
                    name,
                    t,
                    subset[i + 1].type,
                });
                return PredicateError.InvalidArgument;
            }
        }
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Get Source with Callback using 1024 bytes buffers

    const MatchRangeResult = union(enum) {
        match: struct {
            match: ?Query.Match = null,
            cap_name: []const u8 = "",
            cap_node: ?b.Node = null,
            directives: ?[]Directive,
        },
        ignore: bool,
    };

    pub fn nextMatchInLines(
        self: *@This(),
        query: *const Query,
        cursor: *Query.Cursor,
        content_callback: F,
        ctx: *anyopaque,
        start_line: usize,
        end_line: usize,
    ) MatchRangeResult {
        while (true) {
            const next_match_zone = ztracy.ZoneNC(@src(), "cursor.nextMatch()", 0xAA5522);
            const match = cursor.nextMatch() orelse {
                next_match_zone.Name("no more nextMatch()");
                next_match_zone.End();
                return .{ .match = .{} };
            };
            next_match_zone.End();

            const all_match = self.allPredicatesMatchesInLines(content_callback, ctx, match);
            if (!all_match) continue;

            var cap_name: []const u8 = "";
            var cap_node: b.Node = undefined;

            for (match.captures()) |cap| {
                const candidate = query.getCaptureNameForId(cap.id);
                if (!std.mem.startsWith(u8, candidate, "_")) {
                    cap_name = candidate;
                    cap_node = cap.node;
                    break;
                }
            }

            if (cap_name.len == 0) {
                std.log.err("capture_name.len == 0!", .{});
                return .{ .ignore = true };
            }

            if (cap_node.getStartPoint().row > end_line or cap_node.getEndPoint().row < start_line) {
                return .{ .ignore = true };
            }

            return .{
                .match = .{
                    .match = match,
                    .cap_name = cap_name,
                    .cap_node = cap_node,
                    .directives = self.directives.get(match.pattern_index),
                },
            };
        }
    }

    fn allPredicatesMatchesInLines(self: *@This(), content_callback: F, ctx: *anyopaque, match: Query.Match) bool {
        const zone = ztracy.ZoneNC(@src(), "allPredicatesMatchesInLines()", 0xAAFF22);
        defer zone.End();

        for (match.captures()) |cap| {
            const node = cap.node;

            const buf_size = 1024;
            var buf: [buf_size]u8 = undefined;
            const node_contents = content_callback(ctx, node.getStartByte(), node.getEndByte(), &buf, buf_size);

            const predicates = self.patterns[match.pattern_index];
            for (predicates) |predicate| if (!predicate.eval(node_contents)) return false;
        }
        return true;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Contiguous String Source

    pub fn nextMatch(self: *@This(), source: []const u8, cursor: *Query.Cursor) ?Query.Match {
        while (true) {
            const match = cursor.nextMatch() orelse return null;
            if (self.allPredicateMatches(source, match)) return match;
        }
    }

    fn allPredicateMatches(self: *@This(), source: []const u8, match: Query.Match) bool {
        for (match.captures()) |cap| {
            const node = cap.node;
            const node_contents = source[node.getStartByte()..node.getEndByte()];
            const predicates = self.patterns[match.pattern_index];
            for (predicates) |predicate| if (!predicate.eval(node_contents)) return false;
        }
        return true;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// Predicates

    const EqPredicate = struct {
        capture: []const u8,
        target: []const u8,
        variant: EqPredicateVariant,

        const EqPredicateVariant = enum { eq, not_eq };

        fn create(query: *const Query, steps: []const PredicateStep, variant: EqPredicateVariant) PredicateError!Predicate {
            checkBodySteps("#eq? / #not-eq?", steps, &.{ .capture, .string }) catch |err| return err;
            return Predicate{
                .eq = EqPredicate{
                    .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                    .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
                    .variant = variant,
                },
            };
        }

        fn eval(self: *const EqPredicate, source: []const u8) bool {
            const zone = ztracy.ZoneNC(@src(), "EqPredicate", 0xAAAAAA);
            defer zone.End();
            return switch (self.variant) {
                .eq => eql(u8, source, self.target),
                .not_eq => !eql(u8, source, self.target),
            };
        }
    };

    const AnyOfPredicate = struct {
        capture: []const u8,
        targets: [][]const u8,

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
            if (steps.len < 4) {
                std.log.err("Expected steps.len to be > 4, got {d}\n", .{steps.len});
                return PredicateError.InvalidAmountOfSteps;
            }
            if (steps[1].type != .capture) {
                std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
                return PredicateError.InvalidArgument;
            }

            var targets = std.ArrayList([]const u8).init(a);
            errdefer targets.deinit();
            for (2..steps.len - 1) |i| {
                if (steps[i].type != .string) {
                    std.log.err("Arguments second and beyond of #any-of? predicate must be type .string, got {any}", .{steps[i].type});
                    return PredicateError.InvalidArgument;
                }
                try targets.append(query.getStringValueForId(steps[i].value_id));
            }

            return Predicate{
                .any_of = AnyOfPredicate{
                    .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                    .targets = try targets.toOwnedSlice(),
                },
            };
        }

        fn eval(self: *const AnyOfPredicate, source: []const u8) bool {
            const zone = ztracy.ZoneNC(@src(), "AnyOfPredicate", 0x00AA00);
            defer zone.End();
            for (self.targets) |target| if (eql(u8, source, target)) return true;
            return false;
        }
    };

    const MatchPredicate = struct {
        capture: []const u8,
        regex: *Regex,
        variant: MatchPredicateVariant,

        const MatchPredicateVariant = enum { match, not_match };

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep, variant: MatchPredicateVariant) PredicateError!Predicate {
            checkBodySteps("#match? / #not-match?", steps, &.{ .capture, .string }) catch |err| return err;

            const regex = try a.create(Regex);
            regex.* = Regex.compile(a, query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)))) catch return PredicateError.RegexCompileError;

            return Predicate{
                .match = MatchPredicate{
                    .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                    .regex = regex,
                    .variant = variant,
                },
            };
        }

        fn eval(self: *const MatchPredicate, source: []const u8) bool {
            const zone = ztracy.ZoneNC(@src(), "MatchPredicate", 0xFF000F);
            defer zone.End();

            const result = self.regex.match(source) catch return false;
            return switch (self.variant) {
                .match => result,
                .not_match => !result,
            };
        }
    };

    const PredicateError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown, RegexCompileError, UnsupportedDirective };
    const Predicate = union(enum) {
        eq: EqPredicate,
        any_of: AnyOfPredicate,
        match: MatchPredicate,
        unsupported,

        fn create(a: Allocator, query: *const Query, name: []const u8, steps: []const PredicateStep) PredicateError!Predicate {
            if (eql(u8, name, "eq?")) return EqPredicate.create(query, steps, .eq);
            if (eql(u8, name, "not-eq?")) return EqPredicate.create(query, steps, .not_eq);
            if (eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
            if (eql(u8, name, "match?")) return MatchPredicate.create(a, query, steps, .match);
            if (eql(u8, name, "not-match?")) return MatchPredicate.create(a, query, steps, .not_match);
            return Predicate.unsupported;
        }

        fn eval(self: *const Predicate, source: []const u8) bool {
            const zone = ztracy.ZoneNC(@src(), "Predicate.eval()", 0x00AA00);
            defer zone.End();

            return switch (self.*) {
                .eq => self.eq.eval(source),
                .any_of => self.any_of.eval(source),
                .match => self.match.eval(source),
                .unsupported => true,
            };
        }
    };

    ////////////////////////////////////////////////////////////////////////////////////////////// Directives

    const Directive = union(enum) {
        set: struct {
            property: []const u8,
            value: []const u8,
        },

        fn create(name: []const u8, query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
            if (eql(u8, name, "set!")) return createSetPredicate(query, steps);
            return PredicateError.UnsupportedDirective;
        }

        fn createSetPredicate(query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
            checkBodySteps("set!", steps, &.{ .string, .string }) catch |err| return err;
            return Directive{
                .set = .{
                    .property = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))),
                    .value = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
                },
            };
        }
    };
};

//////////////////////////////////////////////////////////////////////////////////////////////

const test_source =
    \\const std = @import("std");
    \\const ztracy = @import("ztracy");
    \\const not_false = true;
    \\const String = []const u8;
;

////////////////////////////////////////////////////////////////////////////////////////////// Predicates

test "no predicate" {
    const patterns = "((IDENTIFIER) @variable)";
    try testFilter(test_source, patterns, &.{ "std", "ztracy", "not_false", "String" });
}

test "#eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#eq? @variable "std"))
    ;
    try testFilter(test_source, patterns, &.{"std"});
}

test "#not-eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#not-eq? @variable "std"))
    ;
    try testFilter(test_source, patterns, &.{ "ztracy", "not_false", "String" });
}

test "#any-of?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "ztracy"))
    ;
    try testFilter(test_source, patterns, &.{ "std", "ztracy" });
}

test "#match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, patterns, &.{"String"});
}

test "#not-match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#not-match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, patterns, &.{ "std", "ztracy", "not_false" });
}

///////////////////////////// Multiple predicates in single pattern

test "#any-of? + #not-eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "ztracy") (#not-eq? @variable "std"))
    ;
    try testFilter(test_source, patterns, &.{"ztracy"});
}

test "#not-eq? + #any-of?" {
    const patterns =
        \\ ((IDENTIFIER) @variable(#not-eq? @variable "std") (#any-of? @variable "std" "ztracy"))
    ;
    try testFilter(test_source, patterns, &.{"ztracy"});
}

////////////////////////////////////////////////////////////////////////////////////////////// Directives

test "trying out directives" {
    const patterns =
        \\ (
        \\   (IDENTIFIER) @variable(#eq? @variable "std")
        \\   (#set! injection.language "vim")
        \\   (#set! priority 105)
        \\ )
    ;
    const query, _ = try setupTestWithNoCleanUp(test_source, patterns);
    var filter = try PredicatesFilter.init(testing_allocator, query);
    defer filter.deinit();

    try eq(1, filter.directives.values().len);
    try eq(2, filter.directives.get(0).?.len);
    try eqStr("injection.language", filter.directives.get(0).?[0].set.property);
    try eqStr("vim", filter.directives.get(0).?[0].set.value);
    try eqStr("priority", filter.directives.get(0).?[1].set.property);
    try eqStr("105", filter.directives.get(0).?[1].set.value);
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn setupTestWithNoCleanUp(source: []const u8, patterns: []const u8) !struct { *b.Query, *b.Query.Cursor } {
    const language = try b.Language.get("zig");
    const query = try b.Query.create(language, patterns);
    var parser = try b.Parser.create();
    try parser.setLanguage(language);
    const tree = try parser.parseString(null, source);
    const cursor = try b.Query.Cursor.create();
    cursor.execute(query, tree.getRootNode());
    return .{ query, cursor };
}

fn testFilter(source: []const u8, patterns: []const u8, expected: []const []const u8) !void {
    const query, const cursor = try setupTestWithNoCleanUp(source, patterns);
    var filter = try PredicatesFilter.init(testing_allocator, query);
    defer filter.deinit();

    var i: usize = 0;
    while (filter.nextMatch(source, cursor)) |match| {
        defer i += 1;
        const node = match.captures()[0].node;
        const node_contents = source[node.getStartByte()..node.getEndByte()];
        try eqStr(expected[i], node_contents);
    }
    try eq(expected.len, i);
}
