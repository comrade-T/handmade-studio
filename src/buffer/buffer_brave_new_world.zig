const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;
const idc_if_it_leaks = std.heap.page_allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

/// Represents a result after walking through a Node.
const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    const keep_walking = WalkResult{ .keep_walking = true };
    const stop = WalkResult{ .keep_walking = false };
    const found = WalkResult{ .found = true };

    const F = *const fn (ctx: *anyopaque, node: *const Node) WalkResult;

    /// Produce a merged walk result from `self` and another WalkResult.
    fn merge(self: WalkResult, right: WalkResult) WalkResult {
        var result = WalkResult{};
        result.err = if (self.err) |_| self.err else right.err;
        result.keep_walking = self.keep_walking and right.keep_walking;
        result.found = self.found or right.found;
        return result;
    }
    test merge {
        try eqDeep(WalkResult.found, merge(WalkResult.found, WalkResult.keep_walking));
        try eqDeep(WalkResult.keep_walking, merge(WalkResult.keep_walking, WalkResult.keep_walking));
        try eqDeep(WalkResult.stop, merge(WalkResult.stop, WalkResult.keep_walking));
    }
};

const empty_leaf_node: Node = .{ .leaf = .{ .buf = "" } };

/// Primary data structure to manage an editable text buffer.
/// Can either be a Branch or a Leaf.
const Node = union(enum) {
    branch: Branch,
    leaf: Leaf,

    /// Create a new Branch node, given a `left` Node and a `right` Node.
    fn new(a: Allocator, left: *const Node, right: *const Node) !*const Node {
        const node = try a.create(Node);
        var w = Weights{};
        w.add(left.weights());
        w.add(right.weights());
        w.depth += 1;
        node.* = .{ .branch = .{ .left = left, .right = right, .weights = w } };
        return node;
    }

    ///////////////////////////// Load

    /// Create 1 single Leaf Node given source string.
    pub fn fromString(a: Allocator, source: []const u8) !*const Node {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, stream.reader(), source.len);
    }
    test fromString {
        const a = idc_if_it_leaks;
        {
            const root = try Node.fromString(a, "hello\nworld");
            var expected = [_]struct { *const Node, ?[]const u8 }{.{ root, "hello\nworld" }};
            try testNodesTraversed(root, &expected);
        }
    }

    /// Use `reader` to read into a buffer, then create 1 single Leaf Node from that.
    fn fromReader(a: Allocator, reader: anytype, buffer_size: usize) !*const Node {
        const buf = try a.alloc(u8, buffer_size);

        const read_size = try reader.read(buf);
        if (read_size != buffer_size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) @panic("unexpected data in final read");

        return Leaf.new(a, buf);
    }

    ///////////////////////////// Walk

    /// Helper function to assert the traversal order of those who use `Node.walk() method.`
    fn testNodesTraversed(root: *const Node, expected: []struct { *const Node, ?[]const u8 }) !void {
        const TestTraverseNodesCtx = struct {
            nodes: *ArrayList(*const Node),
            fn walker(ctx_: *anyopaque, node: *const Node) WalkResult {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.nodes.append(node) catch |e| return WalkResult{ .err = e };
                return WalkResult.keep_walking;
            }
        };

        var collected_nodes = std.ArrayList(*const Node).init(std.testing.allocator);
        defer collected_nodes.deinit();
        var ctx: TestTraverseNodesCtx = .{ .nodes = &collected_nodes };
        const walk_result = root.walkAll(TestTraverseNodesCtx.walker, &ctx);

        try eq(WalkResult.keep_walking, walk_result);
        try eq(expected.len, collected_nodes.items.len);
        for (expected, 0..) |e, i| {
            const expected_node, const may_expected_str = e;
            try eq(expected_node, collected_nodes.items[i]);
            if (may_expected_str) |str| try eqStr(str, collected_nodes.items[i].leaf.buf);
        }
    }

    /// Recursively walk through all of the Node's descendants
    /// and execute walker callback function on descendant Node encountered,
    /// regardless if it's a Branch or a Leaf.
    fn walkAll(self: *const Node, f: WalkResult.F, ctx: *anyopaque) WalkResult {
        const current = f(ctx, self);
        switch (self.*) {
            .branch => |*branch| {
                if (!current.keep_walking) return current;

                const left = branch.left.walkAll(f, ctx);
                if (left.found) return left;

                const right = branch.right.walkAll(f, ctx);
                return left.merge(right);
            },

            .leaf => |_| return current,
        }
    }
    test walkAll {
        const a = idc_if_it_leaks;
        {
            const one_two = try Node.new(a, try Leaf.new(a, "one"), try Leaf.new(a, "_two"));
            const three_four = try Node.new(a, try Leaf.new(a, "_three"), try Leaf.new(a, "_four"));
            const root = try Node.new(a, one_two, three_four);
            var expected = [_]struct { *const Node, ?[]const u8 }{
                .{ root, null },
                .{ root.branch.left, null },
                .{ root.branch.left.branch.left, "one" },
                .{ root.branch.left.branch.right, "_two" },
                .{ root.branch.right, null },
                .{ root.branch.right.branch.left, "_three" },
                .{ root.branch.right.branch.right, "_four" },
            };
            try testNodesTraversed(root, &expected);
        }
    }

    ///////////////////////////// Node Info

    /// Either returns a Branch's `weights` field value
    /// or a Leaf.buffer's length as `Weights`.
    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }
    test weights {
        const a = idc_if_it_leaks;
        const node = try Node.new(a, try Leaf.new(a, "one"), try Leaf.new(a, " two"));
        try eqStr("one", node.branch.left.leaf.buf);
        try eqStr(" two", node.branch.right.leaf.buf);
        try eqDeep(Weights{ .len = 7, .depth = 2 }, node.weights());
        try eqDeep(Weights{ .len = 3, .depth = 1 }, node.branch.left.weights());
        try eqDeep(Weights{ .len = 4, .depth = 1 }, node.branch.right.weights());
    }

    /// Recursively walk through self and check if all the leaves' buffers are empty.
    fn isEmpty(self: *const Node) bool {
        return switch (self.*) {
            .branch => |*b| b.left.isEmpty() and b.right.isEmpty(),
            .leaf => |*l| l.isEmpty(),
        };
    }
    test isEmpty {
        const a = idc_if_it_leaks;
        {
            const node = try Node.new(a, try Leaf.new(a, ""), try Leaf.new(a, ""));
            try eq(true, node.isEmpty());
            try eq(true, node.branch.left.isEmpty());
            try eq(true, node.branch.right.isEmpty());
        }
        {
            const node = try Node.new(a, try Leaf.new(a, ""), try Leaf.new(a, "two"));
            try eq(false, node.isEmpty());
            try eq(true, node.branch.left.isEmpty());
            try eq(false, node.branch.right.isEmpty());
        }
    }

    ///////////////////////////// Debug Print

    /// Prints a Node's info.
    fn debugPrint(self: *const Node) void {
        switch (self.*) {
            .branch => std.debug.print("Branch: depth: {d} | len: {d}\n", .{ self.weights().depth, self.weights().len }),
            .leaf => std.debug.print("Leaf: `{s}` | len: {d}\n", .{ self.leaf.buf, self.leaf.buf.len }),
        }
    }
};

/// A Branch contains pointers to its left and right Nodes.
/// Its `weights.len` has the sum value of its left and right Nodes.
/// Its `weights.depth` has the max value of its left and right Nodes +1.
const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
};

/// A Leaf's only job is to have a `buf` field that points to a slice of bytes.
const Leaf = struct {
    buf: []const u8,

    /// Create a Leaf Node with a `buf` field that points to a slice of bytes.
    inline fn new(a: Allocator, source: []const u8) !*const Node {
        if (source.len == 0) return &empty_leaf_node;
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = source } };
        return node;
    }
    test new {
        {
            const leaf_node = try Leaf.new(idc_if_it_leaks, "");
            try eq(&empty_leaf_node, leaf_node);
        }
        {
            const leaf_node = try Leaf.new(idc_if_it_leaks, "hello");
            try eqStr("hello", leaf_node.leaf.buf);
        }
    }

    /// Returns a `Weights` object with depth of 1 and len of self.buf.len
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

    /// Returns `true` if self.buf.len == 0
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

/// Contains 2 fields: `len` and `depth`.
const Weights = struct {
    len: usize = 0,
    depth: usize = 1,

    /// Mutates `self` in place.
    /// Mutated length is self.len + other.len.
    /// Mutated depth is max value of self.depth vs other.depth.
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
