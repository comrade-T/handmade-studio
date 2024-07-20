const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

const Walker = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    const keep_walking = Walker{ .keep_walking = true };
    const stop = Walker{ .keep_walking = false };
    const found = Walker{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) Walker;
};

const empty_leaf_node: Node = .{ .leaf = .{ .buf = "" } };
const Node = union(enum) {
    branch: Branch,
    leaf: Leaf,

    fn new(a: Allocator, left: *const Node, right: *const Node) !*const Node {
        const node = try a.create(Node);
        var w = Weights{};
        w.add(left.weights());
        w.add(right.weights());
        w.depth += 1;
        node.* = .{ .branch = .{ .left = left, .right = right, .weights = w } };
        return node;
    }

    fn walk(self: *const Node, f: Walker.F, ctx: *anyopaque) Walker {
        switch (self.*) {
            .branch => |*branch| {
                const left_result = branch.left.walk(f, ctx);
                if (!left_result.keep_walking) {
                    var result = Walker{};
                    result.err = left_result.err;
                    result.found = left_result.found;
                    return result;
                }
                const right_result = branch.right.walk(f, ctx);
                return mergeWalkResults(left_result, right_result);
            },
            .leaf => |*l| return f(ctx, l),
        }
    }
    test walk {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const one_two = try Node.new(a, try Leaf.new(a, "one"), try Leaf.new(a, " two"));
        const three_four = try Node.new(a, try Leaf.new(a, " three"), try Leaf.new(a, " four"));
        const root = try Node.new(a, one_two, three_four);

        {
            const CollectLeavesCtx = struct {
                leaves: *ArrayList(*const Leaf),
                fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
                    const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                    ctx.leaves.append(leaf) catch |e| return Walker{ .err = e };
                    return Walker.keep_walking;
                }
            };
            var leaves = std.ArrayList(*const Leaf).init(std.testing.allocator);
            defer leaves.deinit();
            var ctx: CollectLeavesCtx = .{ .leaves = &leaves };
            const walk_result = root.walk(CollectLeavesCtx.walker, &ctx);

            try eq(Walker.keep_walking, walk_result);
            try eqStr("one", leaves.items[0].buf);
            try eqStr(" two", leaves.items[1].buf);
            try eqStr(" three", leaves.items[2].buf);
            try eqStr(" four", leaves.items[3].buf);
        }

        {
            const FindLeafThatSpansAcrossTargetByteIndexCtx = struct {
                target_index: usize,
                result: ?*const Leaf = null,
                current_index: usize = 0,
                fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
                    const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                    const leaf_len = leaf.buf.len;
                    if (ctx.current_index + leaf_len > ctx.target_index) {
                        ctx.result = leaf;
                        return Walker.found;
                    }
                    ctx.current_index += leaf_len;
                    return Walker.keep_walking;
                }
            };

            const testIndexToLeaf = struct {
                fn f(node: *const Node, start: usize, end: usize, expected_str: []const u8) !void {
                    for (start..end) |target_index| {
                        var ctx: FindLeafThatSpansAcrossTargetByteIndexCtx = .{ .target_index = target_index };
                        const walk_result = node.walk(FindLeafThatSpansAcrossTargetByteIndexCtx.walker, &ctx);
                        try eq(Walker.found, walk_result);
                        try eqStr(expected_str, ctx.result.?.*.buf);
                    }
                }
            }.f;
            try testIndexToLeaf(root, 0, 3, "one");
            try testIndexToLeaf(root, 3, 7, " two");
            try testIndexToLeaf(root, 7, 13, " three");
            try testIndexToLeaf(root, 13, 18, " four");
        }
    }

    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }
    test weights {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const node = try Node.new(arena.allocator(), try Leaf.new(a, "one"), try Leaf.new(a, " two"));
        try eqStr("one", node.branch.left.leaf.buf);
        try eqStr(" two", node.branch.right.leaf.buf);
        try eqDeep(Weights{ .len = 7, .depth = 2 }, node.weights());
        try eqDeep(Weights{ .len = 3, .depth = 1 }, node.branch.left.weights());
        try eqDeep(Weights{ .len = 4, .depth = 1 }, node.branch.right.weights());
    }

    fn isEmpty(self: *const Node) bool {
        return switch (self.*) {
            .branch => |*b| b.left.isEmpty() and b.right.isEmpty(),
            .leaf => |*l| l.isEmpty(),
        };
    }
    test isEmpty {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        {
            const node = try Node.new(arena.allocator(), try Leaf.new(a, ""), try Leaf.new(a, ""));
            try eq(true, node.isEmpty());
            try eq(true, node.branch.left.isEmpty());
            try eq(true, node.branch.right.isEmpty());
        }
        {
            const node = try Node.new(arena.allocator(), try Leaf.new(a, ""), try Leaf.new(a, "two"));
            try eq(false, node.isEmpty());
            try eq(true, node.branch.left.isEmpty());
            try eq(false, node.branch.right.isEmpty());
        }
    }
};

fn mergeWalkResults(left: Walker, right: Walker) Walker {
    var result = Walker{};
    result.err = if (left.err) |_| left.err else right.err;
    result.keep_walking = left.keep_walking and right.keep_walking;
    result.found = left.found or right.found;
    return result;
}
test mergeWalkResults {
    try eqDeep(Walker.found, mergeWalkResults(Walker.found, Walker.keep_walking));
    try eqDeep(Walker.keep_walking, mergeWalkResults(Walker.keep_walking, Walker.keep_walking));
    try eqDeep(Walker.stop, mergeWalkResults(Walker.stop, Walker.keep_walking));
}

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
};

const Leaf = struct {
    buf: []const u8,

    inline fn new(a: Allocator, source: []const u8) !*const Node {
        if (source.len == 0) return &empty_leaf_node;
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = source } };
        return node;
    }
    test new {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const node = try Leaf.new(arena.allocator(), "hello");
        try eqStr("hello", node.leaf.buf);
    }

    fn weights(self: *const Leaf) Weights {
        return Weights{ .len = self.buf.len };
    }
    test weights {
        {
            const leaf = Leaf{ .buf = "" };
            try eqDeep(Weights{ .len = 0, .depth = 1 }, leaf.weights());
        }
        {
            const leaf = Leaf{ .buf = "hello" };
            try eqDeep(Weights{ .len = 5, .depth = 1 }, leaf.weights());
        }
    }

    inline fn isEmpty(self: *const Leaf) bool {
        return self.buf.len == 0;
    }
    test isEmpty {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
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
    len: usize = 0,
    depth: usize = 1,

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
