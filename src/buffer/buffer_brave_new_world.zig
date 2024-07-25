const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;
const idc_if_it_leaks = std.heap.page_allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

const WalkerMut = *const fn (ctx: *anyopaque, leaf: *const Node) WalkMutResult;

/// Represents the result of a walk operation on a Node.
/// This walk operation should never mutate the current Node and can potentially return a new Node.
const WalkMutResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    replace: ?*const Node = null,

    const keep_walking = WalkMutResult{ .keep_walking = true };
    const stop = WalkMutResult{ .keep_walking = false };
    const found = WalkMutResult{ .found = true };

    // fn merge(a: Allocator, b: *const Branch, left: WalkMutResult, right: WalkMutResult) WalkMutResult {
    //     return WalkerMut{
    //         .err = if (left.err) |_| left.err else right.err,
    //         .keep_walking = left.keep_walking and right.keep_walking,
    //         .found = left.found or right.found,
    //         .replace = if (left.replace == null and right.replace == null)
    //             null
    //         else
    //             _mergeReplacements(a, b, left, right) catch |e| return WalkerMut{ .err = e },
    //     };
    // }
    //
    // fn _mergeReplacements(a: Allocator, b: *const Branch, left: WalkMutResult, right: WalkMutResult) !*const Node {
    //     const new_left = if (left.replace) |p| p else b.left;
    //     const new_right = if (right.replace) |p| p else b.right;
    //
    //     if (new_left.is_empty()) return new_right;
    //     if (new_right.is_empty()) return new_left;
    //
    //     return Node.new(a, new_left, new_right);
    // }
};

const Walker = *const fn (ctx: *anyopaque, node: *const Node) WalkResult;

/// Represents the result of a walk operation on a Node.
/// This walk operation should never mutate the current Node or create a new Node.
const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    const keep_walking = WalkResult{ .keep_walking = true };
    const stop = WalkResult{ .keep_walking = false };
    const found = WalkResult{ .found = true };

    // /// Produce a merged walk result from `self` and another WalkResult.
    // fn merge(self: WalkResult, right: WalkResult) WalkResult {
    //     return WalkResult{
    //         .err = if (self.err) |_| self.err else right.err,
    //         .keep_walking = self.keep_walking and right.keep_walking,
    //         .found = self.found or right.found,
    //     };
    // }
    // test merge {
    //     try eqDeep(WalkResult.found, merge(WalkResult.found, WalkResult.keep_walking));
    //     try eqDeep(WalkResult.keep_walking, merge(WalkResult.keep_walking, WalkResult.keep_walking));
    //     try eqDeep(WalkResult.stop, merge(WalkResult.stop, WalkResult.keep_walking));
    // }
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
            try eqDeep(Node{ .leaf = .{ .buf = "hello\nworld" } }, root.*);
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

    ///////////////////////////// Balancing

    fn rotateLeft(self: *const Node, allocator: Allocator) !*const Node {
        const other = self.branch.right;
        const a = try Node.new(allocator, self.branch.left, other.branch.left);
        const b = try Node.new(allocator, a, other.branch.right);
        return b;
    }
    test rotateLeft {
        const a = idc_if_it_leaks;
        {
            const acd = try Node.fromString(a, "ACD");
            const abcd = try acd.insertChars(a, 1, "B");
            const old_root = try abcd.insertChars(a, 4, "E");
            const new_root = try old_root.rotateLeft(a);
            try eqDeep(Weights{ .depth = 3, .len = 5 }, new_root.weights());
            try eqDeep(Weights{ .depth = 2, .len = 2 }, new_root.branch.left.weights());
            try eqDeep(Weights{ .depth = 2, .len = 3 }, new_root.branch.right.weights());
            try eqStr("A", new_root.branch.left.branch.left.leaf.buf);
            try eqStr("B", new_root.branch.left.branch.right.leaf.buf);
            try eqStr("CD", new_root.branch.right.branch.left.leaf.buf);
            try eqStr("E", new_root.branch.right.branch.right.leaf.buf);
        }
    }

    ///////////////////////////// Insert Chars

    fn insertChars(self: *const Node, a: Allocator, target_index: usize, chars: []const u8) !*const Node {
        const InsertCharsCtx = struct {
            a: Allocator,
            buf: []const u8,
            current_index: *usize,
            target_index: usize,

            fn walker(cx_: *anyopaque, leaf_node: *const Node) WalkMutResult {
                const cx = @as(*@This(), @ptrCast(@alignCast(cx_)));
                const new_leaf_node = Leaf.new(cx.a, cx.buf) catch |err| return .{ .err = err };

                const leaf_is_empty = leaf_node.leaf.buf.len == 0;
                if (leaf_is_empty) return WalkMutResult{ .replace = new_leaf_node };

                const insert_at_start = cx.current_index.* == cx.target_index;
                if (insert_at_start) {
                    const replacement = Node.new(cx.a, new_leaf_node, leaf_node) catch |err| return .{ .err = err };
                    return WalkMutResult{ .replace = replacement };
                }

                const insert_at_end = cx.current_index.* + leaf_node.leaf.buf.len == cx.target_index;
                if (insert_at_end) {
                    const replacement = Node.new(cx.a, leaf_node, new_leaf_node) catch |err| return .{ .err = err };
                    return WalkMutResult{ .replace = replacement };
                }

                const old_buf = leaf_node.leaf.buf;
                const split_index = cx.target_index - cx.current_index.*;

                const upper_left_content = old_buf[0..split_index];
                const upper_left = Leaf.new(cx.a, upper_left_content) catch |err| return .{ .err = err };

                const left = new_leaf_node;
                const right_content = old_buf[split_index..old_buf.len];
                const right = Leaf.new(cx.a, right_content) catch |err| return .{ .err = err };
                const upper_right = Node.new(cx.a, left, right) catch |err| return .{ .err = err };

                const replacement = Node.new(cx.a, upper_left, upper_right) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = replacement };
            }
        };

        if (target_index > self.weights().len) return error.IndexOutOfBounds;

        const buf = try a.dupe(u8, chars);
        var current_index: usize = 0;
        var ctx = InsertCharsCtx{ .a = a, .buf = buf, .current_index = &current_index, .target_index = target_index };
        const walk_result = self.walkToTargetIndexMut(a, &current_index, target_index, InsertCharsCtx.walker, &ctx);

        if (walk_result.err) |e| return e;
        if (walk_result.replace) |replacement| return replacement;
        return error.NotFound;
    }

    test insertChars {
        const a = idc_if_it_leaks;

        { // replace empty Leaf with new Leaf with new content
            const root = try Node.fromString(a, "");
            const new_root = try root.insertChars(idc_if_it_leaks, 0, "A");
            try eqStr("A", new_root.leaf.buf);
        }
        { // target_index at start of Leaf
            const root = try Node.fromString(a, "BCD");
            const new_root = try root.insertChars(idc_if_it_leaks, 0, "A");
            try eqDeep(Weights{ .depth = 2, .len = 4 }, new_root.weights());
            try eqStr("A", new_root.branch.left.leaf.buf);
            try eqStr("BCD", new_root.branch.right.leaf.buf);
        }
        { // target_index at end of Leaf
            const root = try Node.fromString(a, "A");
            const new_root = try root.insertChars(idc_if_it_leaks, 1, "BCD");
            try eqDeep(Weights{ .depth = 2, .len = 4 }, new_root.weights());
            try eqStr("A", new_root.branch.left.leaf.buf);
            try eqStr("BCD", new_root.branch.right.leaf.buf);
        }
        { // target_index at middle of Leaf
            const root = try Node.fromString(a, "ACD");
            const new_root = try root.insertChars(idc_if_it_leaks, 1, "B");
            try eqDeep(Weights{ .depth = 3, .len = 4 }, new_root.weights());
            try eqDeep(Weights{ .depth = 2, .len = 3 }, new_root.branch.right.weights());
            try eqStr("A", new_root.branch.left.leaf.buf);
            try eqStr("B", new_root.branch.right.branch.left.leaf.buf);
            try eqStr("CD", new_root.branch.right.branch.right.leaf.buf);
        }

        {
            const acd = try Node.fromString(a, "ACD");
            const abcd = try acd.insertChars(idc_if_it_leaks, 1, "B");
            const abcde = try abcd.insertChars(idc_if_it_leaks, 4, "E");
            try eqDeep(Weights{ .depth = 4, .len = 5 }, abcde.weights());
            try eqDeep(Weights{ .depth = 3, .len = 4 }, abcde.branch.right.weights());
            try eqDeep(Weights{ .depth = 2, .len = 3 }, abcde.branch.right.branch.right.weights());
            try eqStr("A", abcde.branch.left.leaf.buf);
            try eqStr("B", abcde.branch.right.branch.left.leaf.buf);
            try eqStr("CD", abcde.branch.right.branch.right.branch.left.leaf.buf);
            try eqStr("E", abcde.branch.right.branch.right.branch.right.leaf.buf);
        }
    }

    ///////////////////////////// walkToTargetIndexMut

    fn walkToTargetIndexMut(self: *const Node, a: Allocator, current_index: *usize, target_index: usize, f: WalkerMut, ctx: *anyopaque) WalkMutResult {
        switch (self.*) {
            .branch => |*branch| {
                const left_end = current_index.* + branch.left.weights().len;

                if (target_index < left_end) {
                    const left_result = branch.left.walkToTargetIndexMut(a, current_index, target_index, f, ctx);
                    return WalkMutResult{
                        .err = left_result.err,
                        .found = left_result.found,
                        .replace = if (left_result.replace) |replacement|
                            Node.new(a, replacement, branch.right) catch |e| return WalkMutResult{ .err = e }
                        else
                            null,
                    };
                }

                current_index.* = left_end;
                const right_result = branch.right.walkToTargetIndexMut(a, current_index, target_index, f, ctx);
                return WalkMutResult{
                    .err = right_result.err,
                    .found = right_result.found,
                    .replace = if (right_result.replace) |replacement|
                        Node.new(a, branch.left, replacement) catch |e| return WalkMutResult{ .err = e }
                    else
                        null,
                };
            },
            .leaf => return f(ctx, self),
        }
    }

    ///////////////////////////// walkToTargetIndex

    /// Wrapper & Test Helper for`Node.walkToTargetIndex()`.
    fn getLeafAtIndex(self: *const Node, target_index: usize) !*const Node {
        if (target_index > self.weights().len - 1) return error.IndexOutOfBounds;

        const GetLeafAtIndexCtx = struct {
            result: ?*const Node = null,
            fn walker(ctx_: *anyopaque, leaf: *const Node) WalkResult {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.result = leaf;
                return WalkResult.found;
            }
        };

        var current_index: usize = 0;
        var ctx = GetLeafAtIndexCtx{};
        const walk_result = self.walkToTargetIndex(&current_index, target_index, GetLeafAtIndexCtx.walker, &ctx);

        if (walk_result.err) |e| return e;
        if (!walk_result.found) return error.NotFound;
        return ctx.result.?;
    }

    test getLeafAtIndex {
        const a = idc_if_it_leaks;
        const one_two = try Node.new(a, try Leaf.new(a, "one"), try Leaf.new(a, "_two"));
        const three_four = try Node.new(a, try Leaf.new(a, "_three"), try Leaf.new(a, "_four"));
        const root = try Node.new(a, one_two, three_four);

        // one
        try eq(root.branch.left.branch.left, try root.getLeafAtIndex(0));
        try eq(root.branch.left.branch.left, try root.getLeafAtIndex(1));
        try eq(root.branch.left.branch.left, try root.getLeafAtIndex(2));

        // _two
        try eq(root.branch.left.branch.right, try root.getLeafAtIndex(3));
        try eq(root.branch.left.branch.right, try root.getLeafAtIndex(4));
        try eq(root.branch.left.branch.right, try root.getLeafAtIndex(5));
        try eq(root.branch.left.branch.right, try root.getLeafAtIndex(6));

        // _three
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(7));
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(8));
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(9));
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(10));
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(11));
        try eq(root.branch.right.branch.left, try root.getLeafAtIndex(12));

        // _four
        try eq(root.branch.right.branch.right, try root.getLeafAtIndex(13));
        try eq(root.branch.right.branch.right, try root.getLeafAtIndex(14));
        try eq(root.branch.right.branch.right, try root.getLeafAtIndex(15));
        try eq(root.branch.right.branch.right, try root.getLeafAtIndex(16));
        try eq(root.branch.right.branch.right, try root.getLeafAtIndex(17));

        // out of bounds
        try shouldErr(error.IndexOutOfBounds, root.getLeafAtIndex(18));
        try shouldErr(error.IndexOutOfBounds, root.getLeafAtIndex(1000));
    }

    /// Recursively walk through this Node, ignoring Brances that end before `target_index`.
    /// Requires caller to own and pass in a *usize for this function to keep track of `current_index` while it walks.
    /// Caller MUST handle out of bounds `target_index`, since
    /// this function will always stop at last Leaf if `target_index` is out of bounds.
    fn walkToTargetIndex(self: *const Node, current_index: *usize, target_index: usize, f: Walker, ctx: *anyopaque) WalkResult {
        switch (self.*) {
            .branch => |*branch| {
                const left_end = current_index.* + branch.left.weights().len;
                if (target_index < left_end) return branch.left.walkToTargetIndex(current_index, target_index, f, ctx);
                current_index.* = left_end;
                return branch.right.walkToTargetIndex(current_index, target_index, f, ctx);
            },
            .leaf => return f(ctx, self),
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
