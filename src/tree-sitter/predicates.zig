// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
const Regex = @import("regex").Regex;
const b = @import("bindings.zig");

const Query = b.Query;
const PredicateStep = b.Query.PredicateStep;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const PredicatesFilter = struct {
    external_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    patterns: [][]Predicate,

    getContentCallback: F = undefined,
    callbackCtx: *anyopaque = undefined,

    const F = *const fn (ctx: *anyopaque, start_byte: usize, end_byte: usize, buf: []u8, buf_size: usize) []const u8;

    pub fn init(external_allocator: Allocator, query: *const Query) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),
            .patterns = undefined,
        };

        var patterns = std.ArrayList([]Predicate).init(self.a);
        errdefer patterns.deinit();
        for (0..query.getPatternCount()) |pattern_index| {
            const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));
            var predicates = std.ArrayList(Predicate).init(self.a);
            errdefer predicates.deinit();

            var start: usize = 0;
            for (steps, 0..) |step, i| {
                if (step.type == .done) {
                    const predicate = try Predicate.create(self.a, query, steps[start .. i + 1]);
                    try predicates.append(predicate);
                    start = i + 1;
                }
            }

            try patterns.append(try predicates.toOwnedSlice());
        }

        self.*.patterns = try patterns.toOwnedSlice();
        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////// With Callback

    pub fn initWithContentCallback(external_allocator: Allocator, query: *const Query, callback: F, ctx: *anyopaque) !*@This() {
        var self = try PredicatesFilter.init(external_allocator, query);
        self.getContentCallback = callback;
        self.callbackCtx = ctx;
        return self;
    }

    ///////////////////////////// Everything

    pub fn nextMatchOnDemand(self: *@This(), cursor: *Query.Cursor) ?Query.Match {
        while (true) {
            const match = cursor.nextMatch() orelse return null;
            if (self.allPredicateMatchesOnDemand(match)) return match;
        }
    }

    fn allPredicateMatchesOnDemand(self: *@This(), match: Query.Match) bool {
        for (match.captures()) |cap| {
            const node = cap.node;

            const buf_size = 1024;
            var buf: [buf_size]u8 = undefined;
            const node_contents = self.getContentCallback(self.callbackCtx, node.getStartByte(), node.getEndByte(), &buf, buf_size);

            const predicates = self.patterns[match.pattern_index];
            for (predicates) |predicate| if (!predicate.eval(self.a, node_contents)) return false;
        }
        return true;
    }

    ///////////////////////////// Limited Range

    pub fn nextMatchInRange(self: *@This(), cursor: *Query.Cursor, start_byte: usize, end_byte: usize) ?Query.Match {
        while (true) {
            const match = cursor.nextMatch() orelse return null;
            if (self.allPredicatesMatchesInRange(match, start_byte, end_byte)) return match;
        }
    }

    fn allPredicatesMatchesInRange(self: *@This(), match: Query.Match, start_byte: usize, end_byte: usize) bool {
        for (match.captures()) |cap| {
            const node = cap.node;
            const node_start = node.getStartByte();
            const node_end = node.getEndByte();

            if (node_end < start_byte) return false;
            if (node_start > end_byte) return false;

            const buf_size = 1024;
            var buf: [buf_size]u8 = undefined;
            const node_contents = self.getContentCallback(self.callbackCtx, node_start, node_end, &buf, buf_size);

            const predicates = self.patterns[match.pattern_index];
            for (predicates) |predicate| if (!predicate.eval(self.a, node_contents)) return false;
        }
        return true;
    }

    //////////////////////////////////////////////////////////////////////////////////////////////

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
            for (predicates) |predicate| if (!predicate.eval(self.a, node_contents)) return false;
        }
        return true;
    }

    /////////////////////////////

    const EqPredicate = struct {
        capture: []const u8,
        target: []const u8,
        variant: EqPredicateVariant,

        const EqPredicateVariant = enum { eq, not_eq };

        fn create(query: *const Query, steps: []const PredicateStep, variant: EqPredicateVariant) PredicateError!Predicate {
            if (steps.len != 4) {
                std.log.err("Expected steps.len == 4, got {d}\n", .{steps.len});
                return PredicateError.InvalidAmountOfSteps;
            }
            if (steps[1].type != .capture) {
                std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
                return PredicateError.InvalidArgument;
            }
            if (steps[2].type != .string) {
                std.log.err("Second argument of #eq? predicate must be type .string, got {any}", .{steps[2].type});
                return PredicateError.InvalidArgument;
            }
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
                std.log.err("Expected steps.len to be < 4, got {d}\n", .{steps.len});
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
        regex_pattern: []const u8,
        variant: MatchPredicateVariant,

        const MatchPredicateVariant = enum { match, not_match };

        fn create(query: *const Query, steps: []const PredicateStep, variant: MatchPredicateVariant) PredicateError!Predicate {
            if (steps.len != 4) {
                std.log.err("Expected steps.len == 4, got {d}\n", .{steps.len});
                return PredicateError.InvalidAmountOfSteps;
            }
            if (steps[1].type != .capture) {
                std.log.err("First argument of #match? predicate must be type .capture, got {any}", .{steps[1].type});
                return PredicateError.InvalidArgument;
            }
            if (steps[2].type != .string) {
                std.log.err("Second argument of #match? predicate must be type .string, got {any}", .{steps[2].type});
                return PredicateError.InvalidArgument;
            }
            return Predicate{
                .match = MatchPredicate{
                    .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                    .regex_pattern = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
                    .variant = variant,
                },
            };
        }

        fn eval(self: *const MatchPredicate, a: Allocator, source: []const u8) bool {
            var re = Regex.compile(a, self.regex_pattern) catch return false;
            defer re.deinit();
            const result = re.match(source) catch return false;
            return switch (self.variant) {
                .match => result,
                .not_match => !result,
            };
        }
    };

    const PredicateError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory, Unknown };
    const Predicate = union(enum) {
        eq: EqPredicate,
        any_of: AnyOfPredicate,
        match: MatchPredicate,
        unsupported: enum { unsupported },

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
            if (steps[0].type != .string) {
                std.log.err("First step of predicate isn't .string.", .{});
                return PredicateError.Unknown;
            }
            const name = query.getStringValueForId(@as(u32, @intCast(steps[0].value_id)));

            if (steps[steps.len - 1].type != .done) {
                std.log.err("Last step of predicate {s} isn't .done.", .{name});
                return PredicateError.InvalidArgument;
            }

            if (eql(u8, name, "eq?")) return EqPredicate.create(query, steps, .eq);
            if (eql(u8, name, "not-eq?")) return EqPredicate.create(query, steps, .not_eq);
            if (eql(u8, name, "any-of?")) return AnyOfPredicate.create(a, query, steps);
            if (eql(u8, name, "match?")) return MatchPredicate.create(query, steps, .match);
            if (eql(u8, name, "not-match?")) return MatchPredicate.create(query, steps, .not_match);
            return Predicate{ .unsupported = .unsupported };
        }

        fn eval(self: *const Predicate, a: Allocator, source: []const u8) bool {
            return switch (self.*) {
                .eq => self.eq.eval(source),
                .any_of => self.any_of.eval(source),
                .match => self.match.eval(a, source),
                .unsupported => true,
            };
        }
    };
};
