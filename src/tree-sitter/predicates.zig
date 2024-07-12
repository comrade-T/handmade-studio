// Copied & Edited from https://github.com/ziglibs/treez

const std = @import("std");
const b = @import("bindings.zig");

const Query = b.Query;
const Allocator = std.mem.Allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const EqualPredicate = struct {
    a: []const u8,
    b: union(enum) { string: []const u8, capture: []const u8 },
};
const PredicateList = std.ArrayList(EqualPredicate);
const PredicateMap = std.AutoHashMap(u32, packed struct { index: u32, len: u32 });
const CaptureIdNameMap = std.StringHashMap(u32);

//////////////////////////////////////////////////////////////////////////////////////////////

pub const CursorWithValidation = struct {
    external_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,

    pub fn init(external_allocator: std.mem.Allocator, query: *const Query) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),
        };

        for (0..query.getPatternCount()) |pattern_index| {
            const predicate_steps = query.getPredicatesForPattern(@as(u32, @intCast(pattern_index)));

            std.debug.print("--------------------------\n", .{});

            for (predicate_steps) |step| {
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
