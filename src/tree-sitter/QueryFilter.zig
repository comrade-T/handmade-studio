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
const ztracy = @import("ztracy");

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
const RopeMan = @import("RopeMan");

////////////////////////////////////////////////////////////////////////////////////////////// init()

a: Allocator,
arena: std.heap.ArenaAllocator,
query: *const ts.Query,
patterns: []PredicateMap = undefined,

pub fn init(a: Allocator, query: *const ts.Query) !*QueryFilter {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .query = query,
    };

    var patterns = std.ArrayList(PredicateMap).init(self.arena.allocator());

    for (0..query.getPatternCount()) |pattern_index| {
        const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));
        var predicates_map = PredicateMap.init(self.arena.allocator());

        var start: usize = 0;
        for (steps, 0..) |step, i| {
            if (step.type == .done) {
                defer start = i + 1;
                const subset = steps[start .. i + 1];
                const name = Predicate.checkFirstAndLastSteps(query, subset) catch continue;
                if (name.len == 0) continue;

                if (name[name.len - 1] == '?') {
                    const cap_id, const predicate = try Predicate.create(self.arena.allocator(), query, name, steps[start .. i + 1]);
                    if (predicate == .unsupported) continue;
                    if (predicates_map.getPtr(cap_id)) |list| try list.append(predicate) else {
                        var list = ArrayList(Predicate).init(self.arena.allocator());
                        try list.append(predicate);
                        try predicates_map.put(cap_id, list);
                    }
                    continue;
                }
            }
        }

        try patterns.append(predicates_map);
    }

    self.*.patterns = try patterns.toOwnedSlice();
    return self;
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Predicates

const PredicateMap = std.AutoHashMap(u32, ArrayList(Predicate));

const Predicate = union(enum) {
    eq: EqPredicate,
    not_eq: NotEqPredicate,
    any_of: AnyOfPredicate,
    match: MatchPredicate,
    unsupported,

    const CreationError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown, RegexCompileError, Unsupported };
    const CreationResult = struct { u32, Predicate };

    fn create(a: Allocator, query: *const Query, name: []const u8, steps: []const PredicateStep) CreationError!CreationResult {
        if (eql(u8, name, "eq?")) return EqPredicate.create(query, steps);
        if (eql(u8, name, "not-eq?")) return NotEqPredicate.create(a, query, steps);
        if (eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
        if (eql(u8, name, "match?")) return MatchPredicate.create(a, query, steps, .match);
        if (eql(u8, name, "not-match?")) return MatchPredicate.create(a, query, steps, .not_match);
        return error.Unsupported;
    }

    fn eval(self: *const Predicate, source: []const u8) bool {
        const zone = ztracy.ZoneNC(@src(), "Predicate.eval()", 0x00AAFF);
        defer zone.End();

        return switch (self.*) {
            .eq => self.eq.eval(source),
            .not_eq => self.not_eq.eval(source),
            .any_of => self.any_of.eval(source),
            .match => self.match.eval(source),
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
            const p = Predicate{ .eq = EqPredicate{ .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const EqPredicate, source: []const u8) bool {
            return eql(u8, source, self.target);
        }
    };

    const NotEqPredicate = struct {
        targets: [][]const u8,

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) CreationError!CreationResult {
            try checkVariedStringSteps(steps);
            const p = Predicate{ .not_eq = NotEqPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ steps[1].value_id, p };
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
            const p = Predicate{ .any_of = AnyOfPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ steps[1].value_id, p };
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

            const p = Predicate{ .match = MatchPredicate{
                .regex = regex,
                .variant = variant,
            } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const MatchPredicate, source: []const u8) bool {
            const zone = ztracy.ZoneNC(@src(), "MatchPredicate.eval()", 0x33FF33);
            defer zone.End();

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

////////////////////////////////////////////////////////////////////////////////////////////// QueryFilter.nextMatch()

pub const CapturedTarget = struct {
    capture_id: u16,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub const MatchResult = struct {
    all_predicates_matched: bool,
    targets: []CapturedTarget,
    pattern_index: u16,
};

pub const ContentCallback = *const fn (ctx: *anyopaque, start: struct { usize, usize }, end: struct { usize, usize }, buf: []u8) []const u8;

pub fn nextMatch(self: *@This(), ropeman: *const RopeMan, targets_buf: []u8, targets_buf_capacity: usize, cursor: *Query.Cursor) ?MatchResult {
    const big_zone = ztracy.ZoneNC(@src(), "QueryFilter.nextMatch()", 0xF00000);
    defer big_zone.End();

    var fba = std.heap.FixedBufferAllocator.init(targets_buf);
    var targets = ArrayList(CapturedTarget).initCapacity(fba.allocator(), targets_buf_capacity) catch unreachable;

    var content_buf: [1024]u8 = undefined;
    var match: ts.Query.Match = undefined;
    {
        const cursor_match = ztracy.ZoneNC(@src(), "cursor.nextMatch()", 0xFF9999);
        defer cursor_match.End();
        match = cursor.nextMatch() orelse return null;
    }

    const predicates_map = self.patterns[match.pattern_index];
    var all_predicates_matched = true;

    for (match.captures()) |cap| {
        const start = cap.node.getStartPoint();
        const end = cap.node.getEndPoint();
        const node_contents = ropeman.getRange(
            .{ .line = @intCast(start.row), .col = @intCast(start.column) },
            .{ .line = @intCast(end.row), .col = @intCast(end.column) },
            &content_buf,
        );
        const cap_name = self.query.getCaptureNameForId(cap.id);

        if (predicates_map.get(cap.id)) |predicates| {
            for (predicates.items) |p| {
                if (!p.eval(node_contents)) {
                    all_predicates_matched = false;
                    break;
                }
            }
        }

        if (cap_name[0] != '_') {
            const start_point = cap.node.getStartPoint();
            const end_point = cap.node.getEndPoint();
            targets.append(CapturedTarget{
                .capture_id = @intCast(cap.id),
                .start_line = start_point.row,
                .start_col = start_point.column,
                .end_line = end_point.row,
                .end_col = end_point.column,
            }) catch break;
        }
    }

    return MatchResult{
        .all_predicates_matched = all_predicates_matched,
        .targets = targets.toOwnedSlice() catch unreachable,
        .pattern_index = @intCast(match.pattern_index),
    };
}

////////////////////////////////////////////////////////////////////////////////////////////// Tests

const test_source = @embedFile("fixtures/predicates_test_dummy.zig");

test "no predicate" {
    const patterns = "((IDENTIFIER) @variable)";
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"mem"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"add"} },
        .{ .targets = &.{"variable"}, .contents = &.{"x"} },
        .{ .targets = &.{"variable"}, .contents = &.{"y"} },
        .{ .targets = &.{"variable"}, .contents = &.{"x"} },
        .{ .targets = &.{"variable"}, .contents = &.{"y"} },
        .{ .targets = &.{"variable"}, .contents = &.{"sub"} },
        .{ .targets = &.{"variable"}, .contents = &.{"a"} },
        .{ .targets = &.{"variable"}, .contents = &.{"b"} },
        .{ .targets = &.{"variable"}, .contents = &.{"a"} },
        .{ .targets = &.{"variable"}, .contents = &.{"b"} },
        .{ .targets = &.{"variable"}, .contents = &.{"callAddExample"} },
        .{ .targets = &.{"variable"}, .contents = &.{"_"} },
        .{ .targets = &.{"variable"}, .contents = &.{"add"} },
        .{ .targets = &.{"variable"}, .contents = &.{"not_false"} },
        .{ .targets = &.{"variable"}, .contents = &.{"xxx"} },
        .{ .targets = &.{"variable"}, .contents = &.{"yyy"} },
        .{ .targets = &.{"variable"}, .contents = &.{"String"} },
    });
}

test "#eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#eq? @variable "add"))
        ;
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
        });
    }
    {
        const patterns =
            \\ (FnProto (IDENTIFIER) @cap (#eq? @cap "add"))
        ;
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{"cap"}, .contents = &.{"add"} },
        });
    }
}

test "#not-eq?" {
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std"))
        ;
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
            .{ .targets = &.{"variable"}, .contents = &.{"mem"} },
            .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
            .{ .targets = &.{"variable"}, .contents = &.{"x"} },
            .{ .targets = &.{"variable"}, .contents = &.{"y"} },
            .{ .targets = &.{"variable"}, .contents = &.{"x"} },
            .{ .targets = &.{"variable"}, .contents = &.{"y"} },
            .{ .targets = &.{"variable"}, .contents = &.{"sub"} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"} },
            .{ .targets = &.{"variable"}, .contents = &.{"callAddExample"} },
            .{ .targets = &.{"variable"}, .contents = &.{"_"} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
            .{ .targets = &.{"variable"}, .contents = &.{"not_false"} },
            .{ .targets = &.{"variable"}, .contents = &.{"xxx"} },
            .{ .targets = &.{"variable"}, .contents = &.{"yyy"} },
            .{ .targets = &.{"variable"}, .contents = &.{"String"} },
        });
    }
    {
        const patterns =
            \\ ((IDENTIFIER) @variable (#not-eq? @variable "std" "Allocator"))
        ;
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{"variable"}, .contents = &.{"mem"} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
            .{ .targets = &.{"variable"}, .contents = &.{"x"} },
            .{ .targets = &.{"variable"}, .contents = &.{"y"} },
            .{ .targets = &.{"variable"}, .contents = &.{"x"} },
            .{ .targets = &.{"variable"}, .contents = &.{"y"} },
            .{ .targets = &.{"variable"}, .contents = &.{"sub"} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"} },
            .{ .targets = &.{"variable"}, .contents = &.{"a"} },
            .{ .targets = &.{"variable"}, .contents = &.{"b"} },
            .{ .targets = &.{"variable"}, .contents = &.{"callAddExample"} },
            .{ .targets = &.{"variable"}, .contents = &.{"_"} },
            .{ .targets = &.{"variable"}, .contents = &.{"add"} },
            .{ .targets = &.{"variable"}, .contents = &.{"not_false"} },
            .{ .targets = &.{"variable"}, .contents = &.{"xxx"} },
            .{ .targets = &.{"variable"}, .contents = &.{"yyy"} },
            .{ .targets = &.{"variable"}, .contents = &.{"String"} },
        });
    }
}

test "#any-of?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "Allocator"))
    ;
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
    });
}

test "#match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"String"} },
    });
}

test "#not-match?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#not-match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$"))
    ;
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"std"} },
        .{ .targets = &.{"variable"}, .contents = &.{"mem"} },
        .{ .targets = &.{"variable"}, .contents = &.{"add"} },
        .{ .targets = &.{"variable"}, .contents = &.{"x"} },
        .{ .targets = &.{"variable"}, .contents = &.{"y"} },
        .{ .targets = &.{"variable"}, .contents = &.{"x"} },
        .{ .targets = &.{"variable"}, .contents = &.{"y"} },
        .{ .targets = &.{"variable"}, .contents = &.{"sub"} },
        .{ .targets = &.{"variable"}, .contents = &.{"a"} },
        .{ .targets = &.{"variable"}, .contents = &.{"b"} },
        .{ .targets = &.{"variable"}, .contents = &.{"a"} },
        .{ .targets = &.{"variable"}, .contents = &.{"b"} },
        .{ .targets = &.{"variable"}, .contents = &.{"callAddExample"} },
        .{ .targets = &.{"variable"}, .contents = &.{"_"} },
        .{ .targets = &.{"variable"}, .contents = &.{"add"} },
        .{ .targets = &.{"variable"}, .contents = &.{"not_false"} },
        .{ .targets = &.{"variable"}, .contents = &.{"xxx"} },
        .{ .targets = &.{"variable"}, .contents = &.{"yyy"} },
    });
}

///////////////////////////// Multiple predicates in single pattern

test "#any-of? + #not-eq?" {
    const patterns =
        \\ ((IDENTIFIER) @variable (#any-of? @variable "std" "Allocator") (#not-eq? @variable "std"))
    ;
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
        .{ .targets = &.{"variable"}, .contents = &.{"Allocator"} },
    });
}

test "#match? + #not-eq?" {
    const patterns =
        \\((IDENTIFIER) @variable (#match? @variable "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
        \\                        (#not-eq? @variable "Allocator"))
    ;
    try testFilter(test_source, null, patterns, &.{
        .{ .targets = &.{"variable"}, .contents = &.{"String"} },
    });
}

///////////////////////////// More Complex Patterns

test "get return type for functions that are not named 'callAddExample'" {
    { // ignore capture groups prefixed with '_'
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
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{"return_type"}, .contents = &.{"f32"} },
            .{ .targets = &.{"return_type"}, .contents = &.{"f64"} },
        });
    }
    { // include capture groups NOT prefixed with '_'
        const patterns =
            \\(
            \\  FnProto
            \\    (IDENTIFIER) @fn.name (#not-eq? @fn.name "callAddExample")
            \\    _?
            \\    (ErrorUnionExpr
            \\      (SuffixExpr
            \\        (BuildinTypeExpr) @return_type
            \\      )
            \\    )
            \\)
        ;
        try testFilter(test_source, null, patterns, &.{
            .{ .targets = &.{ "fn.name", "return_type" }, .contents = &.{ "add", "f32" } },
            .{ .targets = &.{ "fn.name", "return_type" }, .contents = &.{ "sub", "f64" } },
        });
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Measuring Contest

test {
    try eq(4, @alignOf(CapturedTarget));
    try eq(20, @sizeOf(CapturedTarget));
}

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

pub const MatchLimit = struct {
    start_line: usize,
    end_line: usize,
};

const Expected = struct {
    targets: []const []const u8,
    contents: []const []const u8,
};

fn testFilter(source: []const u8, may_limit: ?MatchLimit, patterns: []const u8, expected: []const Expected) !void {
    const query, const cursor = try setupTestWithNoCleanUp(source, may_limit, patterns);
    var filter = try QueryFilter.init(testing_allocator, query);
    defer filter.deinit();

    var ropeman = try RopeMan.initFrom(testing_allocator, .string, source);
    defer ropeman.deinit();

    const target_buf_capacity = 8;
    var targets_buf: [@sizeOf(CapturedTarget) * target_buf_capacity]u8 = undefined;
    var i: usize = 0;
    while (filter.nextMatch(&ropeman, &targets_buf, target_buf_capacity, cursor)) |match| {
        if (!match.all_predicates_matched) continue;
        try eq(expected[i].targets.len, match.targets.len);
        for (0..expected[i].targets.len) |j| {
            try eqStr(expected[i].targets[j], query.getCaptureNameForId(match.targets[j].capture_id));
            try testMatchContents(expected[i].contents[j], source, match.targets[j]);
        }
        i += 1;
    }

    try eq(expected.len, i);
}

fn testMatchContents(expected: []const u8, source: []const u8, target: CapturedTarget) !void {
    var bytes = ArrayList(u8).init(std.heap.page_allocator);
    defer bytes.deinit();

    var split_iter = std.mem.split(u8, source, "\n");
    var i: usize = 0;
    while (split_iter.next()) |line| {
        defer i += 1;
        if (i == target.start_line and target.start_line == target.end_line) {
            try bytes.appendSlice(line[target.start_col..target.end_col]);
            break;
        }
        if (i > target.start_line) try bytes.appendSlice("\n");
    }

    try eqStr(expected, bytes.items);
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
