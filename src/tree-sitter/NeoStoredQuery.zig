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

//////////////////////////////////////////////////////////////////////////////////////////////

const StoredQuery = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const ts = @import("bindings.zig");
const NeoBuffer = @import("NeoBuffer");

const mvzr = @import("mvzr");
const Regex = mvzr.Regex;

//////////////////////////////////////////////////////////////////////////////////////////////

query: *ts.Query = undefined,
pattern_string: []const u8 = undefined,
arena: std.heap.ArenaAllocator = undefined,
patterns: []PredicateMap = undefined,

pub fn init(a: Allocator, ts_lang: *const ts.Language, pattern_string: []const u8) !StoredQuery {
    var self = StoredQuery{};
    self.arena = std.heap.ArenaAllocator.init(a);
    self.pattern_string = try self.arena.allocator().dupe(u8, pattern_string);
    self.query = try ts.Query.create(ts_lang, self.pattern_string);

    var patterns = std.ArrayList(PredicateMap).init(self.arena.allocator());

    for (0..self.query.getPatternCount()) |pattern_index| {
        const steps = self.query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));
        var predicates_map = PredicateMap.init(self.arena.allocator());

        var start: usize = 0;
        for (steps, 0..) |step, i| {
            if (step.type == .done) {
                defer start = i + 1;
                const subset = steps[start .. i + 1];
                const name = Predicate.checkFirstAndLastSteps(self.query, subset) catch continue;
                if (name.len == 0) continue;

                if (name[name.len - 1] == '?') {
                    const cap_id, const predicate = Predicate.create(self.arena.allocator(), self.query, name, steps[start .. i + 1]) catch continue;
                    if (predicates_map.getPtr(cap_id)) |list| try list.append(predicate) else {
                        var list = std.ArrayListUnmanaged(Predicate){};
                        try list.append(self.arena.allocator(), predicate);
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
    self.query.destroy();
}

////////////////////////////////////////////////////////////////////////////////////////////// Predicate

const PredicateMap = std.AutoHashMap(u32, std.ArrayListUnmanaged(Predicate));

const Predicate = union(enum) {
    eq: EqPredicate,
    not_eq: NotEqPredicate,
    any_of: AnyOfPredicate,
    match: MatchPredicate,
    starts_with: StartsWithPredicate,
    ends_with: EndsWithPredicate,
    unsupported,

    const CreationError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown, RegexCompileError, Unsupported };
    const CreationResult = struct { u32, Predicate };

    fn create(a: Allocator, query: *const ts.Query, name: []const u8, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
        if (std.mem.eql(u8, name, "eq?")) return EqPredicate.create(query, steps);
        if (std.mem.eql(u8, name, "not-eq?")) return NotEqPredicate.create(a, query, steps);
        if (std.mem.eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
        if (std.mem.eql(u8, name, "match?")) return MatchPredicate.create(a, query, steps, .match);
        if (std.mem.eql(u8, name, "not-match?")) return MatchPredicate.create(a, query, steps, .not_match);
        if (std.mem.eql(u8, name, "starts-with?")) return StartsWithPredicate.create(query, steps);
        if (std.mem.eql(u8, name, "ends-with?")) return EndsWithPredicate.create(query, steps);
        return UnsupportedPredicate.create(steps);
    }

    fn eval(self: *const Predicate, source: []const u8) bool {
        return switch (self.*) {
            .eq => self.eq.eval(source),
            .not_eq => self.not_eq.eval(source),
            .any_of => self.any_of.eval(source),
            .match => self.match.eval(source),
            .starts_with => self.starts_with.eval(source),
            .ends_with => self.ends_with.eval(source),
            .unsupported => false,
        };
    }

    fn checkFirstAndLastSteps(query: *const ts.Query, subset: []const ts.Query.PredicateStep) CreationError![]const u8 {
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

    fn checkBodySteps(name: []const u8, subset: []const ts.Query.PredicateStep, types: []const ts.Query.PredicateStep.Type) CreationError!void {
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

    fn checkVariedStringSteps(steps: []const ts.Query.PredicateStep) !void {
        if (steps.len < 4) {
            std.log.err("Expected steps.len to be > 4, got {d}\n", .{steps.len});
            return CreationError.InvalidAmountOfSteps;
        }
        if (steps[1].type != .capture) {
            std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
            return CreationError.InvalidArgument;
        }
    }

    fn gatherVariedStringTargets(a: Allocator, query: *const ts.Query, steps: []const ts.Query.PredicateStep) ![][]const u8 {
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

        fn create(query: *const ts.Query, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            checkBodySteps("#eq?", steps, &.{ .capture, .string }) catch |err| return err;
            const p = Predicate{ .eq = EqPredicate{ .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const EqPredicate, source: []const u8) bool {
            return std.mem.eql(u8, source, self.target);
        }
    };

    const NotEqPredicate = struct {
        targets: [][]const u8,

        fn create(a: Allocator, query: *const ts.Query, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            try checkVariedStringSteps(steps);
            const p = Predicate{ .not_eq = NotEqPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const NotEqPredicate, source: []const u8) bool {
            for (self.targets) |target| if (std.mem.eql(u8, source, target)) return false;
            return true;
        }
    };

    const AnyOfPredicate = struct {
        targets: [][]const u8,

        fn create(a: Allocator, query: *const ts.Query, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            try checkVariedStringSteps(steps);
            const p = Predicate{ .any_of = AnyOfPredicate{ .targets = try gatherVariedStringTargets(a, query, steps) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const AnyOfPredicate, source: []const u8) bool {
            for (self.targets) |target| if (std.mem.eql(u8, source, target)) return true;
            return false;
        }
    };

    const MatchPredicate = struct {
        regex: *Regex,
        variant: MatchPredicateVariant,

        const MatchPredicateVariant = enum { match, not_match };

        fn create(a: Allocator, query: *const ts.Query, steps: []const ts.Query.PredicateStep, variant: MatchPredicateVariant) CreationError!CreationResult {
            checkBodySteps("#match? / #not-match?", steps, &.{ .capture, .string }) catch |err| return err;

            const regex = try a.create(Regex);
            regex.* = Regex.compile(query.getStringValueForId(@as(u32, @intCast(steps[2].value_id)))) orelse return CreationError.RegexCompileError;

            const p = Predicate{ .match = MatchPredicate{
                .regex = regex,
                .variant = variant,
            } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const MatchPredicate, source: []const u8) bool {
            const result = self.regex.match(source) orelse return false;

            return switch (self.variant) {
                .match => result.slice.len > 0,
                .not_match => result.slice.len == 0,
            };
        }
    };

    const StartsWithPredicate = struct {
        target: []const u8,

        fn create(query: *const ts.Query, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            checkBodySteps("#starts-with?", steps, &.{ .capture, .string }) catch |err| return err;
            const p = Predicate{ .starts_with = StartsWithPredicate{ .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const StartsWithPredicate, source: []const u8) bool {
            if (source.len < self.target.len) return false;
            return std.mem.eql(u8, source[0..self.target.len], self.target);
        }
    };

    const EndsWithPredicate = struct {
        target: []const u8,

        fn create(query: *const ts.Query, steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            checkBodySteps("#ends-with?", steps, &.{ .capture, .string }) catch |err| return err;
            const p = Predicate{ .ends_with = EndsWithPredicate{ .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))) } };
            return .{ steps[1].value_id, p };
        }

        fn eval(self: *const EndsWithPredicate, source: []const u8) bool {
            if (source.len < self.target.len) return false;
            return std.mem.eql(u8, source[source.len - self.target.len ..], self.target);
        }
    };

    const UnsupportedPredicate = struct {
        fn create(steps: []const ts.Query.PredicateStep) CreationError!CreationResult {
            if (steps.len < 2) return error.InvalidAmountOfSteps;
            return .{ steps[1].value_id, Predicate.unsupported };
        }
    };
};

////////////////////////////////////////////////////////////////////////////////////////////// Match

pub fn nextMatch(self: *@This(), query_cursor: *ts.Query.Cursor, buffer: *const NeoBuffer) ?ts.Query.Match {
    const match = query_cursor.nextMatch() orelse return null;

    const predicates_map = self.patterns[match.pattern_index];
    var content_buf: [256]u8 = undefined;

    for (match.captures()) |cap| {
        const start = cap.node.getStartPoint();
        const end = cap.node.getEndPoint();
        const node_contents = buffer.getRange(
            .{ .line = @intCast(start.row), .col = @intCast(start.column) },
            .{ .line = @intCast(end.row), .col = @intCast(end.column) },
            &content_buf,
        );

        if (predicates_map.get(cap.id)) |predicates| {
            for (predicates.items) |p| if (!p.eval(node_contents)) return null;
        }
    }

    return match;
}
