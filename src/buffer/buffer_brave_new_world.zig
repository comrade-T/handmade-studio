const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

const Node = union(enum) {
    leaf: Leaf,
    branch: Branch,
};

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
};

const empty_leaf: Node = .{ .leaf = .{ .buf = "" } };
const Leaf = struct {
    buf: []const u8,

    inline fn new(a: Allocator, source: []const u8) !*const Node {
        if (source.len == 0) return &empty_leaf;
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = source } };
        return node;
    }

    test new {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const node = try Leaf.new(arena.allocator(), "hello");
        try eqStr("hello", node.leaf.buf);
    }

    inline fn isEmpty(self: *const Leaf) bool {
        return self.buf.len == 0;
    }

    test isEmpty {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        {
            const node = try Leaf.new(arena.allocator(), "hello");
            try eq(false, node.leaf.isEmpty());
        }
        {
            const node = try Leaf.new(arena.allocator(), "");
            try eq(true, node.leaf.isEmpty());
        }
    }
};

test Leaf {
    _ = Leaf{ .buf = "" };
}

const Weights = struct {
    len: u32 = 0,
    depth: u32 = 1,

    inline fn add(self: *Weights, other: Weights) void {
        self.len += other.len;
        self.depth = @max(self.depth, other.depth);
    }

    test add {
        {
            var w = Weights{};
            w.add(Weights{});
            try eqDeep(Weights{ .len = 0, .depth = 1 }, w);
        }
        {
            var w = Weights{ .len = 1 };
            w.add(Weights{ .len = 2 });
            try eqDeep(Weights{ .len = 3, .depth = 1 }, w);
        }
    }
};

test Weights {
    _ = Weights{};
}
