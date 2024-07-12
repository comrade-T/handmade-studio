const std = @import("std");
const Buffer = @import("buffer").Buffer;

const Allocator = std.mem.Allocator;

const Window = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,

    buffer: *Buffer,

    pub fn create(external_allocator: Allocator) !*@This() {
        var self = try external_allocator.create(@This());

        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(external_allocator),
            .a = self.arena.allocator(),

            .buffer = try Buffer.create(self.a, self.a),
        };

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.buffer.deinit();
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }
};

test Window {
    const a = std.testing.allocator;

    var window = try Window.create(a);
    defer window.deinit();
}
