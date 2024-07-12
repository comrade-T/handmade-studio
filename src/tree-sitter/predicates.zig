// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
const b = @import("bindings.zig");

const Query = b.Query;
const PredicateStep = b.Query.PredicateStep;
const Allocator = std.mem.Allocator;
const StringList = std.ArrayList([]const u8);
const eql = std.mem.eql;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const CursorWithValidation = struct {
    external_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,

    const PredicateError = error{ Unsupported, InvalidAmountOfSteps, InvalidArgument };
    const Predicate = union(enum) {
        eq: struct {
            capture: []const u8,
            target: []const u8,
        },
        any_of: struct {
            capture: []const u8,
            targets: StringList,
        },
    };

    fn createPredicate(a: Allocator, query: *const Query, steps: []*PredicateStep) PredicateError!Predicate {
        const name = query.getStringValueForId(@as(u32, @intCast(steps[0].value_id)));

        if (eql(u8, name, "eq?")) {
            if (steps.len != 3) return PredicateError.InvalidAmountOfSteps;
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
            if (steps.len < 3) return PredicateError.InvalidAmountOfSteps;
            if (steps[1].type != .capture) {
                std.log.err("First argument of #eq? predicate must be type .capture, got {any}", .{steps[1].type});
                return PredicateError.InvalidArgument;
            }

            var target_list = StringList.init(a);
            errdefer target_list.deinit();
            for (2..steps.len) |i| {
                if (steps[i].type != .string) {
                    std.log.err("Arguments second and beyond of #any-of? predicate must be type .string, got {any}", .{steps[i].type});
                    return PredicateError.InvalidArgument;
                }
                target_list.append(query.getStringValueForId(steps[i].value_id));
            }

            return Predicate{
                .any_of = .{
                    .capture = query.getCaptureNameForId(@as(u32, @intCast(steps[1].value_id))),
                    .targets = target_list,
                },
            };
        }

        return PredicateError.Unsupported;
    }

    pub fn init(external_allocator: Allocator, query: *const Query) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),
        };

        for (0..query.getPatternCount()) |pattern_index| {
            const steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));

            if (steps.len == 0) continue;
            if (steps[0].type != .string) continue;

            const predicate = try createPredicate(self.a, steps);
            std.debug.print("predicate = {any}\n", .{predicate});

            for (1..steps.len) |i| {
                const step = steps[i];
                switch (step.type) {
                    .string => {
                        const str_arg = query.getStringValueForId(@as(u32, @intCast(step.value_id)));
                        std.debug.print(".string => {s}\n", .{str_arg});
                    },
                    .capture => {
                        const capture_name = query.getCaptureNameForId(@as(u32, @intCast(step.value_id)));
                        std.debug.print(".capture => {s}\n", .{capture_name});
                    },
                    .done => {},
                }
            }
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }
};
