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
query: *const ts.Query,
patterns: []PredicateMap = undefined,
directives: DirectiveMap,

pub fn init(a: Allocator, query: *const ts.Query) !*QueryFilter {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .query = query,
        .directives = DirectiveMap.init(self.arena.allocator()),
    };

    var patterns = std.ArrayList(PredicateMap).init(self.arena.allocator());

    for (0..query.getPatternCount()) |pattern_index| {
        const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));
        var pmap = PredicateMap.init(self.arena.allocator());
        var directives = ArrayList(Directive).init(self.arena.allocator());

        if (steps.len == 0) {
            const cap_name = query.getCaptureNameForId(@as(u32, @intCast(0)));
            if (pmap.getPtr(cap_name)) |list| try list.append(.capture) else {
                var list = ArrayList(Predicate).init(self.arena.allocator());
                try list.append(.capture);
                try pmap.put(cap_name, list);
            }
        }

        var start: usize = 0;
        for (steps, 0..) |step, i| {
            if (step.type == .done) {
                defer start = i + 1;
                const subset = steps[start .. i + 1];

                if (subset[0].type == .capture and subset[0].type == .done) {
                    const cap_name = query.getCaptureNameForId(@as(u32, @intCast(subset[0].value_id)));
                    if (pmap.getPtr(cap_name)) |list| try list.append(.capture) else {
                        var list = ArrayList(Predicate).init(self.arena.allocator());
                        try list.append(.capture);
                        try pmap.put(cap_name, list);
                    }
                    continue;
                }

                const name = Predicate.checkFirstAndLastSteps(query, subset) catch continue;
                if (name.len == 0) continue;
                if (name[name.len - 1] == '?') {
                    const cap_name, const predicate = try Predicate.create(self.arena.allocator(), query, name, steps[start .. i + 1]);
                    if (predicate != .unsupported) {
                        if (pmap.getPtr(cap_name)) |list| try list.append(predicate) else {
                            var list = ArrayList(Predicate).init(self.arena.allocator());
                            try list.append(predicate);
                            try pmap.put(cap_name, list);
                        }
                    }
                    continue;
                }
                if (name[name.len - 1] == '!') {
                    const directive = Directive.create(name, query, subset) catch continue;
                    try directives.append(directive);
                }
            }
        }

        try patterns.append(pmap);

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

const PredicateMap = std.StringHashMap(ArrayList(Predicate));

const Predicate = union(enum) {
    eq: EqPredicate,
    not_eq: NotEqPredicate,
    any_of: AnyOfPredicate,
    match: MatchPredicate,
    capture,
    unsupported,

    const CreationError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown, RegexCompileError, UnsupportedDirective };
    const CreationResult = struct { []const u8, Predicate };

    fn create(a: Allocator, query: *const Query, name: []const u8, steps: []const PredicateStep) CreationError!CreationResult {
        if (eql(u8, name, "eq?")) return EqPredicate.create(query, steps);
        if (eql(u8, name, "not-eq?")) return NotEqPredicate.create(a, query, steps);
        if (eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
        if (eql(u8, name, "match?")) return MatchPredicate.create(a, query, steps, .match);
        if (eql(u8, name, "not-match?")) return MatchPredicate.create(a, query, steps, .not_match);
        return .{ &.{}, Predicate.unsupported };
    }

    fn eval(self: *const Predicate, source: []const u8) bool {
        return switch (self.*) {
            .eq => self.eq.eval(source),
            .not_eq => self.not_eq.eval(source),
            .any_of => self.any_of.eval(source),
            .match => self.match.eval(source),
            .capture => true,
            .unsupported => false,
        };
    }

    fn checkFirstAndLastSteps(query: *const Query, subset: []const PredicateStep) CreationError![]const u8 {
        if (subset[0].type != .string) {
            std.log.err("First step of predicate isn't .string.", .{});
            return CreationError.Unknown;
        }
        const name = query.getStringValueForId(@as(u32, @intCast(subset[0].value_id)));
        if (subset[subset.len - 1].type != .done) {
            std.log.err("Last step of predicate '{s}' isn't .done.", .{name});
            return CreationError.InvalidArgument;
        }
        return name;
    }

    fn checkBodySteps(name: []const u8, subset: []const PredicateStep, types: []const PredicateStep.Type) CreationError!void {
        if (subset.len -| types.len != 2) return CreationError.InvalidAmountOfSteps;
        for (types, 0..) |t, i| {
            if (subset[i + 1].type != t) {
                std.log.err("Argument #{d} of '{s}' must be type '{any}, not '{any}'", .{
                    i,
                    name,
                    t,
                    subset[i + 1].type,
                });
                return CreationError.InvalidArgument;
            }
        }
    }

    fn checkVariedStringSteps(steps: []const PredicateStep) !void {
        if (steps.len < 4) {
            std.log.err("Expected steps.len to be > 4, got {d}\n", .{steps.len});
            return CreationError.InvalidAmountOfSteps;
        }
        if (steps[1].type != .capture) {
            std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
            return CreationError.InvalidArgument;
        }
    }

    fn gatherVariedStringTargets(a: Allocator, query: *const Query, steps: []const PredicateStep) ![][]const u8 {
        var targets = std.ArrayList([]const u8).init(a);
        errdefer targets.deinit();
        for (2..steps.len - 1) |i| {
            if (steps[i].type != .string) {
                std.log.err("Arguments second and beyond of #any-of? predicate must be type .string, got {any}", .{steps[i].type});
                return CreationError.InvalidArgument;
            }
            try targets.append(query.getStringValueForId(steps[i].value_id));
        }
        return try targets.toOwnedSlice();
    }

    const EqPredicate = struct {
        target: []const u8,

        fn create(query: *const Query, steps: []const PredicateStep) CreationError!CreationResult {
            checkBodySteps("#eq?", steps, &.{ .capture, .string }) catch |err| return err;
            const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
            const p = Predicate{ .eq = EqPredicate{ .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))) } };
            return .{ capture, p };
        }

        fn eval(self: *const EqPredicate, source: []const u8) bool {
            return eql(u8, source, self.target);
        }
    };

    const NotEqPredicate = struct {
        targets: [][]const u8,

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) CreationError!CreationResult {
            try checkVariedStringSteps(steps);
            const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
            const p = Predicate{ .not_eq = NotEqPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ capture, p };
        }

        fn eval(self: *const NotEqPredicate, source: []const u8) bool {
            for (self.targets) |target| if (eql(u8, source, target)) return false;
            return true;
        }
    };

    const AnyOfPredicate = struct {
        targets: [][]const u8,

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) CreationError!CreationResult {
            try checkVariedStringSteps(steps);
            const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
            const p = Predicate{ .any_of = AnyOfPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ capture, p };
        }

        fn eval(self: *const AnyOfPredicate, source: []const u8) bool {
            for (self.targets) |target| if (eql(u8, source, target)) return true;
            return false;
        }
    };

    const MatchPredicate = struct {
        regex: *Regex,
        variant: MatchPredicateVariant,

        const MatchPredicateVariant = enum { match, not_match };

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep, variant: MatchPredicateVariant) CreationError!CreationResult {
            checkBodySteps("#match? / #not-match?", steps, &.{ .capture, .string }) catch |err| return err;

            const regex = try a.create(Regex);
            regex.* = Regex.compile(a, query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)))) catch return CreationError.RegexCompileError;

            const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
            const p = Predicate{ .match = MatchPredicate{
                .regex = regex,
                .variant = variant,
            } };
            return .{ capture, p };
        }

        fn eval(self: *const MatchPredicate, source: []const u8) bool {
            const result = self.regex.match(source) catch return false;
            return switch (self.variant) {
                .match => result,
                .not_match => !result,
            };
        }
    };
};

fn isPredicateOfTypeTarget(steps: []const PredicateStep) bool {
    if (steps[0].type == .capture and steps[1].type == .done) return true;
    return false;
}

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

    fn create(name: []const u8, query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        if (eql(u8, name, "set!")) return createSetDirective(query, steps);
        if (eql(u8, name, "size!")) return createSizeDirective(query, steps);
        if (eql(u8, name, "font!")) return createFontDirective(query, steps);
        if (eql(u8, name, "img!")) return createImgDirective(query, steps);
        return Predicate.CreationError.UnsupportedDirective;
    }

    fn createSizeDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("size!", steps, &.{.string}) catch |err| return err;
        const str_value = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id)));
        return Directive{ .size = std.fmt.parseFloat(f32, str_value) catch 0 };
    }

    fn createFontDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("font!", steps, &.{.string}) catch |err| return err;
        return Directive{ .font = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))) };
    }

    fn createImgDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("img!", steps, &.{.string}) catch |err| return err;
        return Directive{ .img = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))) };
    }

    fn createSetDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("set!", steps, &.{ .string, .string }) catch |err| return err;
        return Directive{
            .set = .{
                .property = query.getStringValueForId(@as(u32, @intCast(steps[1].value_id))),
                .value = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
            },
        };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// QueryFilter.nextMatch()

const CaptureResult = struct {
    node: ts.Node,
    name: []const u8,
};

pub fn getCaptures(self: *@This(), a: Allocator, source: []const u8, cursor: *Query.Cursor) ![]CaptureResult {
    var results = ArrayList(CaptureResult).init(a);
    errdefer results.deinit();

    while (true) {
        const match = cursor.nextMatch() orelse break;
        const pmap = self.patterns[match.pattern_index];

        var all_matched = true;
        var candidates = ArrayList(CaptureResult).init(a);
        errdefer candidates.deinit();

        for (match.captures()) |cap| {
            const node = cap.node;
            const node_contents = source[node.getStartByte()..node.getEndByte()];
            const cap_name = self.query.getCaptureNameForId(cap.id);

            if (cap_name.len > 0 and cap_name[0] != '_') {
                try candidates.append(.{ .name = cap_name, .node = node });
            }

            if (pmap.get(cap_name)) |predicates| {
                for (predicates.items) |p| {
                    if (!p.eval(node_contents)) {
                        all_matched = false;
                        break;
                    }
                }
            }

            if (all_matched) try results.appendSlice(candidates.items);
            candidates.deinit();
        }
    }

    return results.toOwnedSlice();
}

////////////////////////////////////////////////////////////////////////////////////////////// Tests - Predicates

const predicates_test_dummy = @embedFile("fixtures/predicates_test_dummy.zig");

test "no predicate" {
    const patterns = "((IDENTIFIER) @variable)";
    try testFilter(predicates_test_dummy, patterns, &.{
        "std",            "Allocator", "std", "mem",       "Allocator",
        "add",            "x",         "y",   "x",         "y",
        "sub",            "a",         "b",   "a",         "b",
        "callAddExample", "_",         "add", "not_false", "xxx",
        "yyy",            "String",
    });
}

test "#eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#eq? @variable "add"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{ "add", "add" });
    }
    {
        const patterns =
            \\ (FnProto (IDENTIFIER) @cap (#eq? @cap "add"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{"add"});
    }
}

test "#not-eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{
            "Allocator", "mem", "Allocator", "add",    "x", "y",              "x", "y",
            "sub",       "a",   "b",         "a",      "b", "callAddExample", "_", "add",
            "not_false", "xxx", "yyy",       "String",
        });
    }
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std" "Allocator"))
        ;
        try testFilter(predicates_test_dummy, patterns, &.{
            "mem",       "add", "x",   "y",      "x",              "y", "sub",
            "a",         "b",   "a",   "b",      "callAddExample", "_", "add",
            "not_false", "xxx", "yyy", "String",
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
        "std",       "std", "mem", "add", "x", "y",              "x", "y",
        "sub",       "a",   "b",   "a",   "b", "callAddExample", "_", "add",
        "not_false", "xxx", "yyy",
    });
}

// ///////////////////////////// Multiple predicates in single pattern

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

///////////////////////////// Complex Patterns

test "get return type for functions that are not named 'callAddExample'" {
    const patterns =
        \\(
        \\  FnProto
        \\    (IDENTIFIER) @_fn.name (#not-eq? @_fn.name "callAddExample")
        \\    _?
        \\    (ErrorUnionExpr
        \\      (SuffixExpr
        \\        (BuildinTypeExpr) @return_type
        \\      )
        \\    )
        \\)
    ;
    try testFilter(predicates_test_dummy, patterns, &.{ "f32", "f32" });
}

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

fn testFilter(source: []const u8, patterns: []const u8, expected: []const []const u8) !void {
    const query, const cursor = try setupTestWithNoCleanUp(source, patterns);
    var filter = try QueryFilter.init(testing_allocator, query);
    defer filter.deinit();

    const results = try filter.getCaptures(testing_allocator, source, cursor);
    defer testing_allocator.free(results);

    try eq(expected.len, results.len);

    for (0..expected.len) |i| {
        const node = results[i].node;
        const node_contents = source[node.getStartByte()..node.getEndByte()];
        try eqStr(expected[i], node_contents);
    }
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
