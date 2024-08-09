const std = @import("std");

const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const Window = struct {
    a: Allocator,

    x: i32 = 0,
    y: i32 = 0,
    width: ?i32 = null,
    height: ?i32 = null,

    pub fn spawn(a: Allocator) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            // TODO:
        };
        return self;
    }

    pub fn destroy(self: *@This()) void {
        self.a.destroy(self);
    }
};

test {
    std.testing.refAllDecls(Window);
}
