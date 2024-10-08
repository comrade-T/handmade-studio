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
        var predicates_map = PredicateMap.init(self.arena.allocator());
        var directives = ArrayList(Directive).init(self.arena.allocator());

        var start: usize = 0;
        for (steps, 0..) |step, i| {
            if (step.type == .done) {
                defer start = i + 1;
                const subset = steps[start .. i + 1];
                const name = Predicate.checkFirstAndLastSteps(query, subset) catch continue;
                if (name.len == 0) continue;

                if (name[name.len - 1] == '?') {
                    const cap_name, const predicate = try Predicate.create(self.arena.allocator(), query, name, steps[start .. i + 1]);
                    if (predicate == .unsupported) continue;
                    if (predicates_map.getPtr(cap_name)) |list| try list.append(predicate) else {
                        var list = ArrayList(Predicate).init(self.arena.allocator());
                        try list.append(predicate);
                        try predicates_map.put(cap_name, list);
                    }
                    continue;
                }

                if (name[name.len - 1] == '!') {
                    const directive = Directive.create(name, query, subset) catch continue;
                    try directives.append(directive);
                }
            }
        }

        try patterns.append(predicates_map);

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
    font_size: struct {
        capture: []const u8,
        value: f32,
    },
    font_face: struct {
        capture: []const u8,
        value: []const u8,
    },
    font: struct {
        capture: []const u8,
        font_face: []const u8,
        font_size: f32,
    },
    img: struct {
        capture: []const u8,
        path: []const u8,
    },
    // TODO: add color directive

    fn create(name: []const u8, query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        if (eql(u8, name, "font!")) return createFontDirective(query, steps);
        if (eql(u8, name, "font-size!")) return createFontSizeDirective(query, steps);
        if (eql(u8, name, "font-face!")) return createFontFaceDirective(query, steps);
        if (eql(u8, name, "img!")) return createImgDirective(query, steps);
        return Predicate.CreationError.UnsupportedDirective;
    }

    fn createFontSizeDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("font-size!", steps, &.{ .capture, .string }) catch |err| return err;
        const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
        const str_value = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)));
        return Directive{ .font_size = .{
            .capture = capture,
            .value = std.fmt.parseFloat(f32, str_value) catch 0,
        } };
    }

    fn createFontFaceDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("font-face!", steps, &.{ .capture, .string }) catch |err| return err;
        const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
        const font_face = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)));
        return Directive{ .font_face = .{ .capture = capture, .value = font_face } };
    }

    fn createFontDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("font!", steps, &.{ .capture, .string, .string }) catch |err| return err;
        const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
        const font_face = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)));
        const size_str = query.getStringValueForId(@as(u32, @intCast(steps[3].value_id)));
        return Directive{ .font = .{
            .capture = capture,
            .font_face = font_face,
            .font_size = std.fmt.parseFloat(f32, size_str) catch 0,
        } };
    }

    fn createImgDirective(query: *const Query, steps: []const PredicateStep) Predicate.CreationError!Directive {
        Predicate.checkBodySteps("img!", steps, &.{ .capture, .string }) catch |err| return err;
        const capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id)));
        const path = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)));
        return Directive{ .img = .{ .capture = capture, .path = path } };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// QueryFilter.nextMatch()

const CapturedTarget = struct {
    node: ts.Node,
    name: []const u8,
};

const MatchResult = struct {
    targets: []CapturedTarget,
    directives: []Directive,
};

pub fn getAllMatches(self: *@This(), a: Allocator, source: []const u8, offset: usize, cursor: *Query.Cursor) ![]MatchResult {
    var results = ArrayList(MatchResult).init(a);
    errdefer results.deinit();

    while (cursor.nextMatch()) |match| {
        const predicates_map = self.patterns[match.pattern_index];

        var all_predicates_matches = true;
        var targets = ArrayList(CapturedTarget).init(a);
        errdefer targets.deinit();

        for (match.captures()) |cap| {
            const node_start_byte = cap.node.getStartByte();
            const node_end_byte = cap.node.getEndByte();

            assert(node_start_byte >= offset);
            if (node_start_byte < offset) continue;

            const start_byte = node_start_byte - offset;
            const end_byte = node_end_byte - offset;

            const node_contents = source[start_byte..end_byte];
            const cap_name = self.query.getCaptureNameForId(cap.id);

            if (cap_name.len > 0 and cap_name[0] != '_') {
                try targets.append(CapturedTarget{ .name = cap_name, .node = cap.node });
            }

            if (predicates_map.get(cap_name)) |predicates| {
                for (predicates.items) |p| {
                    if (!p.eval(node_contents)) {
                        all_predicates_matches = false;
                        break;
                    }
                }
            }
        }

        if (all_predicates_matches) try results.append(MatchResult{
            .targets = try targets.toOwnedSlice(),
            .directives = self.directives.get(match.pattern_index) orelse &.{},
        });

        targets.deinit();
    }

    return results.toOwnedSlice();
}

////////////////////////////////////////////////////////////////////////////////////////////// Tests - Predicates

const test_source = @embedFile("fixtures/predicates_test_dummy.zig");

test "no predicate" {
    const patterns = "((IDENTIFIER) @variable)";
    try testFilter(test_source, patterns, &.{
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
        try testFilter(test_source, patterns, &.{ "add", "add" });
    }
    {
        const patterns =
            \\ (FnProto (IDENTIFIER) @cap (#eq? @cap "add"))
        ;
        try testFilter(test_source, patterns, &.{"add"});
    }
}

test "#not-eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std"))
        ;
        try testFilter(test_source, patterns, &.{
            "Allocator", "mem", "Allocator", "add",    "x", "y",              "x", "y",
            "sub",       "a",   "b",         "a",      "b", "callAddExample", "_", "add",
            "not_false", "xxx", "yyy",       "String",
        });
    }
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std" "Allocator"))
        ;
        try testFilter(test_source, patterns, &.{
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
    try testFilter(test_source, patterns, &.{ "std", "Allocator", "std", "Allocator" });
}

test "#match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, patterns, &.{ "Allocator", "Allocator", "String" });
}

test "#not-match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#not-match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, patterns, &.{
        "std",       "std", "mem", "add", "x", "y",              "x", "y",
        "sub",       "a",   "b",   "a",   "b", "callAddExample", "_", "add",
        "not_false", "xxx", "yyy",
    });
}

///////////////////////////// Multiple predicates in single pattern

test "#any-of? + #not-eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "Allocator") (#not-eq? @variable "std"))
    ;
    try testFilter(test_source, patterns, &.{ "Allocator", "Allocator" });
}

test "#match? + #not-eq?" {
    const patterns =
        \\((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
        \\                        (#not-eq? @variable "Allocator"))
    ;
    try testFilter(test_source, patterns, &.{"String"});
}

///////////////////////////// More Complex Patterns

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
    try testFilter(test_source, patterns, &.{ "f32", "f64" });
}

///////////////////////////// Directives

test "get directives" {
    const patterns =
        \\(
        \\  FnProto
        \\    (IDENTIFIER) @fn_name (#not-eq? @fn_name "callAddExample") (#font-size! @fn_name 60)
        \\    _?
        \\    (ErrorUnionExpr
        \\      (SuffixExpr
        \\        (BuildinTypeExpr) @return_type
        \\        (#font! @return_type "Inter" 80)
        \\      )
        \\    )
        \\)
    ;
    try testFilterWithDirectives(test_source, .{ .offset = 0, .start_line = 0, .end_line = 21 }, patterns, &.{
        .{
            .targets = &.{ "fn_name", "return_type" },
            .contents = &.{ "add", "f32" },
            .directives = &.{
                .{ .font_size = .{ .capture = "fn_name", .value = 60 } },
                .{ .font = .{ .capture = "return_type", .font_face = "Inter", .font_size = 80 } },
            },
        },
        .{
            .targets = &.{ "fn_name", "return_type" },
            .contents = &.{ "sub", "f64" },
            .directives = &.{
                .{ .font_size = .{ .capture = "fn_name", .value = 60 } },
                .{ .font = .{ .capture = "return_type", .font_face = "Inter", .font_size = 80 } },
            },
        },
    });
}

///////////////////////////// Offset

test "get directives within certain range" {
    {
        const patterns =
            \\(
            \\  FnProto
            \\    (IDENTIFIER) @fn_name (#not-eq? @fn_name "callAddExample") (#font-size! @fn_name 60)
            \\    _?
            \\    (ErrorUnionExpr
            \\      (SuffixExpr
            \\        (BuildinTypeExpr) @return_type
            \\        (#font-size! @return_type 80)
            \\      )
            \\    )
            \\)
        ;
        try testFilterWithDirectives(test_source, .{
            .offset = getByteOffsetForSkippingLines(test_source, 6),
            .start_line = 6,
            .end_line = 21,
        }, patterns, &.{
            .{
                .targets = &.{ "fn_name", "return_type" },
                .contents = &.{ "sub", "f64" },
                .directives = &.{
                    .{ .font_size = .{ .capture = "fn_name", .value = 60 } },
                    .{ .font_size = .{ .capture = "return_type", .value = 80 } },
                },
            },
        });
    }
    {
        const patterns = "((IDENTIFIER) @variable)";
        try testFilterWithDirectives(test_source, .{
            .offset = getByteOffsetForSkippingLines(test_source, 6),
            .start_line = 6,
            .end_line = 13,
        }, patterns, &.{
            .{ .targets = &.{"variable"}, .contents = &.{"sub"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"callAddExample"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"_"}, .directives = &.{} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"}, .directives = &.{} },
        });
    }
}

fn getByteOffsetForSkippingLines(source: []const u8, lines_to_skip: usize) usize {
    var offset: usize = 0;
    var i: usize = 0;
    for (source) |char| {
        offset += 1;
        if (char == '\n') i += 1;
        if (i == lines_to_skip) break;
    }
    return offset;
}

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

const MatchLimit = struct {
    offset: usize,
    start_line: usize,
    end_line: usize,
};

const Expected = struct {
    targets: []const []const u8,
    contents: []const []const u8,
    directives: []const Directive,
};

fn testFilterWithDirectives(og_source: []const u8, limit: MatchLimit, patterns: []const u8, expected: []const Expected) !void {
    const query, const cursor = try setupTestWithNoCleanUp(og_source, limit, patterns);
    var filter = try QueryFilter.init(testing_allocator, query);
    defer filter.deinit();

    const results = try filter.getAllMatches(testing_allocator, og_source[limit.offset..], limit.offset, cursor);
    defer {
        for (results) |r| testing_allocator.free(r.targets);
        testing_allocator.free(results);
    }

    try eq(expected.len, results.len);

    for (0..expected.len) |i| {
        for (0..expected[i].targets.len) |j| {
            try eqStr(expected[i].targets[j], results[i].targets[j].name);
            const node = results[i].targets[j].node;
            const node_contents = og_source[node.getStartByte()..node.getEndByte()];
            try eqStr(expected[i].contents[j], node_contents);
        }
        try eq(expected[i].directives.len, results[i].directives.len);
        for (0..expected[i].directives.len) |j| {
            try std.testing.expectEqualDeep(expected[i].directives[j], results[i].directives[j]);
        }
    }
}

fn testFilter(source: []const u8, patterns: []const u8, expected: []const []const u8) !void {
    const query, const cursor = try setupTestWithNoCleanUp(source, null, patterns);
    var filter = try QueryFilter.init(testing_allocator, query);
    defer filter.deinit();

    const results = try filter.getAllMatches(testing_allocator, source, 0, cursor);
    defer {
        for (results) |r| testing_allocator.free(r.targets);
        testing_allocator.free(results);
    }

    try eq(expected.len, results.len);

    for (0..expected.len) |i| {
        try eq(1, results[i].targets.len);
        const node = results[i].targets[0].node;
        const node_contents = source[node.getStartByte()..node.getEndByte()];
        try eqStr(expected[i], node_contents);
    }
}

fn setupTestWithNoCleanUp(source: []const u8, may_limit: ?MatchLimit, patterns: []const u8) !struct { *ts.Query, *ts.Query.Cursor } {
    const language = try ts.Language.get("zig");
    const query = try ts.Query.create(language, patterns);
    var parser = try ts.Parser.create();
    try parser.setLanguage(language);
    const tree = try parser.parseString(null, source);
    const cursor = try ts.Query.Cursor.create();
    if (may_limit) |limit| {
        cursor.setPointRange(
            ts.Point{ .row = @intCast(limit.start_line), .column = 0 },
            ts.Point{ .row = @intCast(limit.end_line + 1), .column = 0 },
        );
    }
    cursor.execute(query, tree.getRootNode());
    return .{ query, cursor };
}
