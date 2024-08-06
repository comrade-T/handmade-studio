const std = @import("std");
const rope = @import("rope");

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

pub const Buffer = struct {
    exa: Allocator,
    rope_arena: ArenaAllocator,
    root: *const rope.Node,

    pub fn create(external_allocator: Allocator, from: enum { string, file }, source: []const u8) !*@This() {
        var self = try external_allocator.create(@This());
        self.* = .{
            .exa = external_allocator,
            .rope_arena = ArenaAllocator.init(external_allocator),
            .root = switch (from) {
                .string => try rope.Node.fromString(self.rope_arena.allocator(), source, true),
                .file => try rope.Node.fromFile(self.rope_arena.allocator(), source),
            },
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        self.rope_arena.deinit();
        self.exa.destroy(self);
    }
};
