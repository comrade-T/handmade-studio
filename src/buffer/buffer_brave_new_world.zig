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

    const F = *const fn (ctx: *anyopaque, node: *const Node, node_kind: NodeKind) Walker;
};

const NodeKind = enum { root, left, right, leaf };

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

    fn debugPrint(self: *const Node, kind: NodeKind) void {
        switch (kind) {
            .root => std.debug.print("Root: depth: {d} | len: {d}\n", .{ self.weights().depth, self.weights().len }),
            .left => std.debug.print("Left Branch: depth: {d} | len: {d}\n", .{ self.weights().depth, self.weights().len }),
            .right => std.debug.print("Right Branch: depth: {d} | len: {d}\n", .{ self.weights().depth, self.weights().len }),
            .leaf => std.debug.print("Leaf: `{s}` | len: {d}\n", .{ self.leaf.buf, self.leaf.buf.len }),
        }
    }

    fn walk(self: *const Node, f: Walker.F, ctx: *anyopaque, kind: NodeKind) Walker {
        const current = f(ctx, self, kind);
        switch (self.*) {
            .branch => |*branch| {
                if (!current.keep_walking) return current;

                const left = branch.left.walk(f, ctx, .left);
                if (left.found) return left;

                const right = branch.right.walk(f, ctx, .right);
                return mergeWalkResults(left, right);
            },

            .leaf => |_| return current,
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
            const CollectNodesCtx = struct {
                nodes: *ArrayList(*const Node),
                fn walker(ctx_: *anyopaque, node: *const Node, _: NodeKind) Walker {
                    const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                    ctx.nodes.append(node) catch |e| return Walker{ .err = e };
                    return Walker.keep_walking;
                }
            };
            var nodes = std.ArrayList(*const Node).init(std.testing.allocator);
            defer nodes.deinit();
            var ctx: CollectNodesCtx = .{ .nodes = &nodes };
            const walk_result = root.walk(CollectNodesCtx.walker, &ctx, .root);

            try eq(Walker.keep_walking, walk_result);
            try eq(root, nodes.items[0]);

            try eq(root.branch.left, nodes.items[1]);
            try eq(root.branch.left.branch.left.leaf, nodes.items[2].leaf);
            try eqStr("one", nodes.items[2].leaf.buf);
            try eq(root.branch.left.branch.right.leaf, nodes.items[3].leaf);
            try eqStr(" two", nodes.items[3].leaf.buf);

            try eq(root.branch.right, nodes.items[4]);
            try eq(root.branch.right.branch.left.leaf, nodes.items[5].leaf);
            try eqStr(" three", nodes.items[5].leaf.buf);
            try eq(root.branch.right.branch.right.leaf, nodes.items[6].leaf);
            try eqStr(" four", nodes.items[6].leaf.buf);
        }

        {
            const LeafFinderCtx = struct {
                target_offset: usize,
                nodes_traversed: *std.ArrayList(*const Node),
                current_offset: usize = 0,
                fn walker(ctx_: *anyopaque, node: *const Node, _: NodeKind) Walker {
                    const c = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                    c.nodes_traversed.append(node) catch |err| return Walker{ .err = err };

                    const node_end = c.current_offset + node.weights().len;
                    if (node_end < c.target_offset) {
                        c.current_offset = node_end;
                        return Walker.stop;
                    }

                    const node_contains_target_offset = c.current_offset <= c.target_offset and c.target_offset < node_end;
                    if (node_contains_target_offset) return switch (node.*) {
                        .branch => Walker.keep_walking,
                        .leaf => Walker.found,
                    };

                    c.current_offset = node_end;
                    return Walker.keep_walking;
                }
            };

            {
                var nodes_traversed = std.ArrayList(*const Node).init(std.testing.allocator);
                defer nodes_traversed.deinit();
                var ctx: LeafFinderCtx = .{ .target_offset = 0, .nodes_traversed = &nodes_traversed };
                const walk_result = root.walk(LeafFinderCtx.walker, &ctx, .root);

                try eq(Walker.found, walk_result);
                try eq(3, nodes_traversed.items.len);
                try eq(root, nodes_traversed.items[0]);
                try eq(root.branch.left, nodes_traversed.items[1]);
                try eq(root.branch.left.branch.left, nodes_traversed.items[2]);
                try eqStr("one", nodes_traversed.items[2].leaf.buf);
            }

            {
                var nodes_traversed = std.ArrayList(*const Node).init(std.testing.allocator);
                defer nodes_traversed.deinit();
                var ctx: LeafFinderCtx = .{ .target_offset = 5, .nodes_traversed = &nodes_traversed };
                const walk_result = root.walk(LeafFinderCtx.walker, &ctx, .root);

                try eq(Walker.found, walk_result);
                try eq(4, nodes_traversed.items.len);
                try eq(root, nodes_traversed.items[0]);
                try eq(root.branch.left, nodes_traversed.items[1]);
                try eq(root.branch.left.branch.left, nodes_traversed.items[2]);
                try eq(root.branch.left.branch.right, nodes_traversed.items[3]);
                try eqStr(" two", nodes_traversed.items[3].leaf.buf);
            }

            {
                var nodes_traversed = std.ArrayList(*const Node).init(std.testing.allocator);
                defer nodes_traversed.deinit();
                var ctx: LeafFinderCtx = .{ .target_offset = 10, .nodes_traversed = &nodes_traversed };
                const walk_result = root.walk(LeafFinderCtx.walker, &ctx, .root);

                try eq(Walker.found, walk_result);
                try eq(4, nodes_traversed.items.len);
                try eq(root, nodes_traversed.items[0]);
                try eq(root.branch.left, nodes_traversed.items[1]);
                try eq(root.branch.right, nodes_traversed.items[2]);
                try eq(root.branch.right.branch.left, nodes_traversed.items[3]);
                try eqStr(" three", nodes_traversed.items[3].leaf.buf);
            }

            {
                var nodes_traversed = std.ArrayList(*const Node).init(std.testing.allocator);
                defer nodes_traversed.deinit();
                var ctx: LeafFinderCtx = .{ .target_offset = 15, .nodes_traversed = &nodes_traversed };
                const walk_result = root.walk(LeafFinderCtx.walker, &ctx, .root);

                try eq(Walker.found, walk_result);
                try eq(5, nodes_traversed.items.len);
                try eq(root, nodes_traversed.items[0]);
                try eq(root.branch.left, nodes_traversed.items[1]);
                try eq(root.branch.right, nodes_traversed.items[2]);
                try eq(root.branch.right.branch.left, nodes_traversed.items[3]);
                try eq(root.branch.right.branch.right, nodes_traversed.items[4]);
                try eqStr(" four", nodes_traversed.items[4].leaf.buf);
            }
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
