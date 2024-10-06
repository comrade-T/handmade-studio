// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

const QueryFilter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangSuite = @import("LangSuite.zig");
const ts = @import("bindings.zig");
const Query = ts.Query;
const PredicateStep = ts.Query.PredicateStep;

const Regex = @import("regex").Regex;

////////////////////////////////////////////////////////////////////////////////////////////// init()

a: Allocator,
arena: std.heap.ArenaAllocator,
patterns: [][]Predicate = undefined,
directives: DirectiveMap,

pub fn init(a: Allocator, query: *const ts.Query) !*QueryFilter {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .directives = DirectiveMap.init(self.arena.allocator()),
    };

    var patterns = std.ArrayList([]Predicate).init(self.arena.allocator());

    for (0..query.getPatternCount()) |pattern_index| {
        const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));
        var predicates = ArrayList(Predicate).init(self.arena.allocator());
        var directives = ArrayList(Directive).init(self.arena.allocator());

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

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Predicates

const PredicateError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown, RegexCompileError, UnsupportedDirective };
const Predicate = union(enum) {
    eq: EqPredicate,
    not_eq: NotEqPredicate,
    any_of: AnyOfPredicate,
    match: MatchPredicate,
    unsupported,

    fn create(a: Allocator, query: *const Query, name: []const u8, steps: []const PredicateStep) PredicateError!Predicate {
        if (eql(u8, name, "eq?")) return EqPredicate.create(query, steps);
        if (eql(u8, name, "not-eq?")) return NotEqPredicate.create(a, query, steps);
        if (eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
        if (eql(u8, name, "match?")) return MatchPredicate.create(a, query, steps, .match);
        if (eql(u8, name, "not-match?")) return MatchPredicate.create(a, query, steps, .not_match);
        return Predicate.unsupported;
    }

    fn eval(self: *const Predicate, source: []const u8) bool {
        return switch (self.*) {
            .eq => self.eq.eval(source),
            .not_eq => self.not_eq.eval(source),
            .any_of => self.any_of.eval(source),
            .match => self.match.eval(source),
            .unsupported => true,
        };
    }
};

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

fn checkVariedStringSteps(steps: []const PredicateStep) !void {
    if (steps.len < 4) {
        std.log.err("Expected steps.len to be > 4, got {d}\n", .{steps.len});
        return PredicateError.InvalidAmountOfSteps;
    }
    if (steps[1].type != .capture) {
        std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
        return PredicateError.InvalidArgument;
    }
}

fn gatherVariedStringTargets(a: Allocator, query: *const Query, steps: []const PredicateStep) ![][]const u8 {
    var targets = std.ArrayList([]const u8).init(a);
    errdefer targets.deinit();
    for (2..steps.len - 1) |i| {
        if (steps[i].type != .string) {
            std.log.err("Arguments second and beyond of #any-of? predicate must be type .string, got {any}", .{steps[i].type});
            return PredicateError.InvalidArgument;
        }
        try targets.append(query.getStringValueForId(steps[i].value_id));
    }
    return try targets.toOwnedSlice();
}

const EqPredicate = struct {
    capture: []const u8,
    target: []const u8,

    fn create(query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
        checkBodySteps("#eq?", steps, &.{ .capture, .string }) catch |err| return err;
        return Predicate{
            .eq = EqPredicate{
                .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
            },
        };
    }

    fn eval(self: *const EqPredicate, source: []const u8) bool {
        return eql(u8, source, self.target);
    }
};

const NotEqPredicate = struct {
    capture: []const u8,
    targets: [][]const u8,

    fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
        try checkVariedStringSteps(steps);
        return Predicate{
            .not_eq = NotEqPredicate{
                .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                .targets = try gatherVariedStringTargets(a, query, steps),
            },
        };
    }

    fn eval(self: *const NotEqPredicate, source: []const u8) bool {
        for (self.targets) |target| if (eql(u8, source, target)) return false;
        return true;
    }
};

const AnyOfPredicate = struct {
    capture: []const u8,
    targets: [][]const u8,

    fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
        try checkVariedStringSteps(steps);
        return Predicate{
            .any_of = AnyOfPredicate{
                .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                .targets = try gatherVariedStringTargets(a, query, steps),
            },
        };
    }

    fn eval(self: *const AnyOfPredicate, source: []const u8) bool {
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
        const result = self.regex.match(source) catch return false;
        return switch (self.variant) {
            .match => result,
            .not_match => !result,
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Directives

const DirectiveMap = std.AutoArrayHashMap(usize, []Directive);

const Directive = union(enum) {
    set: struct {
        property: []const u8,
        value: []const u8,
    },
    size: f32,
    font: []const u8,
    img: []const u8,
    // TODO: color: u32 -> not doing right now since I'd have to parse colors

    fn create(name: []const u8, query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
        if (eql(u8, name, "set!")) return createSetDirective(query, steps);
        if (eql(u8, name, "size!")) return createSizeDirective(query, steps);
        if (eql(u8, name, "font!")) return createFontDirective(query, steps);
        if (eql(u8, name, "img!")) return createImgDirective(query, steps);
        return PredicateError.UnsupportedDirective;
    }

    fn createSizeDirective(query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
        checkBodySteps("size!", steps, &.{.string}) catch |err| return err;
        const str_value = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id)));
        return Directive{ .size = std.fmt.parseFloat(f32, str_value) catch 0 };
    }

    fn createFontDirective(query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
        checkBodySteps("font!", steps, &.{.string}) catch |err| return err;
        return Directive{ .font = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))) };
    }

    fn createImgDirective(query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
        checkBodySteps("img!", steps, &.{.string}) catch |err| return err;
        return Directive{ .img = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))) };
    }

    fn createSetDirective(query: *const Query, steps: []const PredicateStep) PredicateError!Directive {
        checkBodySteps("set!", steps, &.{ .string, .string }) catch |err| return err;
        return Directive{
            .set = .{
                .property = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))),
                .value = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
            },
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// QueryFilter.nextMatch()

pub fn nextMatch(self: *@This(), source: []const u8, cursor: *Query.Cursor) ?Query.Match {
    while (true) {
        const match = cursor.nextMatch() orelse return null;
        if (self.allPredicateMatches(source, match)) return match; // FIXME: allPredicateMatches is wrong
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

////////////////////////////////////////////////////////////////////////////////////////////// Tests - Predicates

const predicates_test_dummy = @embedFile("fixtures/predicates_test_dummy.zig");

test "no predicate" {
    const patterns = "((IDENTIFIER) @variable)";
    try testFilter(predicates_test_dummy, patterns, &.{
        "std",       "Allocator", "std", "mem",    "Allocator",
        "add",       "x",         "y",   "x",      "y",
        "sub",       "a",         "b",   "a",      "b",
        "not_false", "xxx",       "yyy", "String",
    });
}

test "#eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#eq? @variable "y"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{ "y", "y" });
}

test "#not-eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{
            "Allocator", "mem", "Allocator", "add", "x", "y",         "x",   "y",
            "sub",       "a",   "b",         "a",   "b", "not_false", "xxx", "yyy",
            "String",
        });
    }
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std" "Allocator"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{
            "mem",    "add", "x", "y", "x",         "y",   "sub",
            "a",      "b",   "a", "b", "not_false", "xxx", "yyy",
            "String",
        });
    }
}

test "#any-of?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "Allocator"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{ "std", "Allocator", "std", "Allocator" });
}

test "#match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{ "Allocator", "Allocator", "String" });
}

test "#not-match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#not-match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{
        "std", "std", "mem", "add", "x", "y",         "x",   "y",
        "sub", "a",   "b",   "a",   "b", "not_false", "xxx", "yyy",
    });
}

///////////////////////////// Multiple predicates in single pattern

test "#any-of? + #not-eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "Allocator") (#not-eq? @variable "std"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{ "Allocator", "Allocator" });
}

test "#match? + #not-eq?" {
    const patterns =
        \\((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
        \\                        (#not-eq? @variable "Allocator"))
    ;
    try testFilter(predicates_test_dummy, patterns, &.{"String"});
}

// TODO: add more tests with more complex queries, like matching a function name

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

fn testFilter(source: []const u8, patterns: []const u8, expected: []const []const u8) !void {
    const query, const cursor = try setupTestWithNoCleanUp(source, patterns);
    var filter = try QueryFilter.init(testing_allocator, query);
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

fn setupTestWithNoCleanUp(source: []const u8, patterns: []const u8) !struct { *ts.Query, *ts.Query.Cursor } {
    const language = try ts.Language.get("zig");
    const query = try ts.Query.create(language, patterns);
    var parser = try ts.Parser.create();
    try parser.setLanguage(language);
    const tree = try parser.parseString(null, source);
    const cursor = try ts.Query.Cursor.create();
    cursor.execute(query, tree.getRootNode());
    return .{ query, cursor };
}
