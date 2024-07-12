// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
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

    fn isValid(_: *@This(), source: []const u8, match: Query.Match) bool {
        for (match.captures(), 0..) |cap, i| {
            const contents = source[cap.node.getStartByte()..cap.node.getEndByte()];
            std.debug.print("i: {d}, contents: {s}\n", .{ i, contents });
        }
        return true;
    }

    pub fn nextMatch(self: *@This(), source: []const u8, cursor: *Query.Cursor) ?Query.Match {
        while (true) {
            const match = cursor.nextMatch() orelse return null;
            if (self.isValid(source, match)) return match;
        }
    }

    /////////////////////////////

    const PredicateError = error{ InvalidAmountOfSteps, InvalidArgument, OutOfMemory };
    const Predicate = union(enum) {
        eq: struct {
            capture: []const u8,
            target: []const u8,
        },
        any_of: struct {
            capture: []const u8,
            targets: [][]const u8,
        },
        unsupported: enum { unsupported },

        fn create(a: Allocator, query: *const Query, steps: []const PredicateStep) PredicateError!Predicate {
            const name = query.getStringValueForId(@as(u32, @intCast(steps[0].value_id)));

            if (steps[steps.len - 1].type != .done) {
                std.log.err("Last step of this predicate {s} isn't .done.", .{name});
                return PredicateError.InvalidArgument;
            }

            if (eql(u8, name, "eq?")) {
                if (steps.len != 4) {
                    std.debug.print("Expected steps.len == 4, got {d}\n", .{steps.len});
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
                    .eq = .{
                        .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                        .target = query.getStringValueForId(@as(u32, @intCast(steps[2].value_id))),
                    },
                };
            }

            if (eql(u8, name, "any-of?")) {
                if (steps.len < 4) return PredicateError.InvalidAmountOfSteps;

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
                    .any_of = .{
                        .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                        .targets = try targets.toOwnedSlice(),
                    },
                };
            }

            return Predicate{ .unsupported = .unsupported };
        }
    };
};
