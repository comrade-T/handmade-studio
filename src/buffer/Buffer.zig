const Buffer = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const rcr = @import("RcRope.zig");
const RcNode = rcr.RcNode;

////////////////////////////////////////////////////////////////////////////////////////////// RopeMan

const RopeMan = struct {
    a: Allocator,
    arena: ArenaAllocator,

    root: RcNode = undefined,
    pending: ArrayList(RcNode),

    fn fromString(a: Allocator, source: []const u8) !RopeMan {
        var ropeman = try RopeMan.init(a);
        ropeman.root = try rcr.Node.fromString(ropeman.a, &ropeman.arena, source);
        return ropeman;
    }

    fn init(a: Allocator) !RopeMan {
        return RopeMan{
            .a = a,
            .arena = ArenaAllocator.init(a),
            .pending = ArrayList(RcNode).init(a),
        };
    }

    fn deinit(self: *@This()) void {
        rcr.freeRcNode(self.root);
        self.pending.deinit();
        self.arena.deinit();
    }
};

test RopeMan {
    var ropeman = try RopeMan.fromString(testing_allocator, "hello");
    defer ropeman.deinit();
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    try eq(2, 2);
}
