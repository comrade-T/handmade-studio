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

////////////////////////////////////////////////////////////////////////////////////////////// @This()

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
        return switch (self.*) {
            .eq => self.eq.eval(source),
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

//////////////////////////////////////////////////////////////////////////////////////////////

// TODO: fix nextMatch() implementation
