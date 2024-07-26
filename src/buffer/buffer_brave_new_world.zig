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

const empty_leaf: Node = .{ .leaf = .{ .buf = "" } };
const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = false } };
const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = true } };
const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = true } };

/// Primary data structure to manage an editable text buffer.
/// Can either be a Branch or a Leaf.
const Node = union(enum) {
    branch: Branch,
    leaf: Leaf,

    /// Create a new Branch Node, given a `left` Node and a `right` Node.
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

    pub fn fromString(a: Allocator, source: []const u8, first_bol: bool) !*const Node {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, stream.reader(), source.len, first_bol);
    }
    test fromString {
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", false);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "hello" }, root.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world" }, root.branch.right.leaf);
        }
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", true);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "hello" }, root.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world" }, root.branch.right.leaf);
        }
    }

    /// Use `reader` to read into a buffer, create leaves by new line from that buffer,
    /// then recursively merge those leaves.
    fn fromReader(a: Allocator, reader: anytype, buffer_size: usize, first_bol: bool) !*const Node {
        const buf = try a.alloc(u8, buffer_size);

        const read_size = try reader.read(buf);
        if (read_size != buffer_size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) @panic("unexpected data in final read");

        var leaves = try createLeavesByNewLine(a, buf);
        leaves[0].leaf.bol = first_bol;
        return try mergeLeaves(a, leaves);
    }

    fn createLeavesByNewLine(a: std.mem.Allocator, buf: []const u8) ![]Node {
        const eol = '\n';

        var leaf_count: usize = 1;
        for (0..buf.len) |i| {
            if (buf[i] == eol) leaf_count += 1;
        }

        var leaves = try a.alloc(Node, leaf_count);
        var cur_leaf: usize = 0;
        var b: usize = 0;
        for (0..buf.len) |i| {
            if (buf[i] == eol) {
                const line = buf[b..i];
                leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .bol = true, .eol = true } };
                cur_leaf += 1;
                b = i + 1;
            }
        }

        const rest = buf[b..];
        leaves[cur_leaf] = .{ .leaf = .{ .buf = rest, .bol = true, .eol = false } };

        leaves[0].leaf.bol = false; // always make first Leaf NOT a .bol

        if (leaves.len != cur_leaf + 1) return error.Unexpected;
        return leaves;
    }
    test createLeavesByNewLine {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "");
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "" }, leaves[0].leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "hello\nworld");
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "hello" }, leaves[0].leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world" }, leaves[1].leaf);
        }
    }

    /// Recursively create and return Nodes given a slice of Leaves.
    fn mergeLeaves(a: Allocator, leaves: []const Node) !*const Node {
        if (leaves.len == 1) return &leaves[0];
        if (leaves.len == 2) return Node.new(a, &leaves[0], &leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try mergeLeaves(a, leaves[0..mid]), try mergeLeaves(a, leaves[mid..]));
    }
    test mergeLeaves {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "one\ntwo\nthree\nfour");
            const root = try mergeLeaves(idc_if_it_leaks, leaves);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "one" }, root.branch.left.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "two" }, root.branch.left.branch.right.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "three" }, root.branch.right.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "four" }, root.branch.right.branch.right.leaf);
        }
    }

    ///////////////////////////// Balancing

    const MAX_IMBALANCE = 1;

    fn calculateBalanceFactor(left: *const Node, right: *const Node) i32 {
        var balance_factor: i32 = @intCast(left.weights().depth);
        balance_factor -= right.weights().depth;
        return balance_factor;
    }

    fn balance(self: *const Node, a: Allocator) !*const Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |branch| {
                const left = try branch.left.balance(a);
                const right = try branch.right.balance(a);

                const balance_factor = calculateBalanceFactor(left, right);

                if (@abs(balance_factor) > MAX_IMBALANCE) {
                    if (balance_factor < 0) {
                        const right_balance_factor = calculateBalanceFactor(right.branch.left, right.branch.right);
                        if (right_balance_factor <= 0) {
                            const this = if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
                            return try this.rotateLeft(a);
                        }

                        const new_right = try right.rotateRight(a);
                        const this = try Node.new(a, left, new_right);
                        return try this.rotateLeft(a);
                    }

                    const left_balance_factor = calculateBalanceFactor(left.branch.left, left.branch.right);
                    if (left_balance_factor >= 0) {
                        const this = if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
                        return try this.rotateRight(a);
                    }

                    const new_left = try left.rotateLeft(a);
                    const this = try Node.new(a, new_left, right);
                    return try this.rotateRight(a);
                }

                return if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
            },
        }
    }
    // test balance {
    //     const a = idc_if_it_leaks;
    //     {
    //         const root = try __inputCharsOneAfterAnother(a, "abcd");
    //         try eqDeep(Weights{ .depth = 4, .len = 4 }, root.weights());
    //         const balanced_root = try root.balance(a);
    //         try eqDeep(Weights{ .depth = 3, .len = 4 }, balanced_root.weights());
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, balanced_root.branch.left.weights());
    //         try eqStr("a", balanced_root.branch.left.branch.left.leaf.buf);
    //         try eqStr("b", balanced_root.branch.left.branch.right.leaf.buf);
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, balanced_root.branch.right.weights());
    //         try eqStr("c", balanced_root.branch.right.branch.left.leaf.buf);
    //         try eqStr("d", balanced_root.branch.right.branch.right.leaf.buf);
    //     }
    //     {
    //         const root = try __inputCharsOneAfterAnother(a, "abcde");
    //         try eqDeep(Weights{ .depth = 5, .len = 5 }, root.weights());
    //         const balanced_root = try root.balance(a);
    //         try eqDeep(Weights{ .depth = 4, .len = 5 }, balanced_root.weights());
    //         try eqDeep(Weights{ .depth = 3, .len = 3 }, balanced_root.branch.left.weights());
    //         try eqStr("a", balanced_root.branch.left.branch.left.leaf.buf);
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, balanced_root.branch.right.weights());
    //         try eqStr("b", balanced_root.branch.left.branch.right.branch.left.leaf.buf);
    //         try eqStr("c", balanced_root.branch.left.branch.right.branch.right.leaf.buf);
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, balanced_root.branch.right.weights());
    //         try eqStr("d", balanced_root.branch.right.branch.left.leaf.buf);
    //         try eqStr("e", balanced_root.branch.right.branch.right.leaf.buf);
    //     }
    // }
    fn __inputCharsOneAfterAnother(a: Allocator, chars: []const u8) !*const Node {
        var root = try Node.fromString(a, "");
        for (0..chars.len) |i| {
            root = try root.insertChars(a, root.weights().len, chars[i .. i + 1]);
        }
        return root;
    }

    fn rotateRight(self: *const Node, allocator: Allocator) !*const Node {
        const other = self.branch.left;
        const a = try Node.new(allocator, other.branch.right, self.branch.right);
        const b = try Node.new(allocator, other.branch.left, a);
        return b;
    }
    // test rotateRight {
    //     const a = idc_if_it_leaks;
    //     {
    //         const abc = try Node.fromString(a, "ACD");
    //         const abcd = try abc.insertChars(a, 1, "B");
    //         const root = try abcd.insertChars(a, 1, "a");
    //
    //         const node_to_rotate = root.branch.right;
    //         try eqDeep(Weights{ .depth = 3, .len = 4 }, node_to_rotate.weights());
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, node_to_rotate.branch.left.weights());
    //         try eqStr("a", node_to_rotate.branch.left.branch.left.leaf.buf);
    //         try eqStr("B", node_to_rotate.branch.left.branch.right.leaf.buf);
    //         try eqDeep(Weights{ .depth = 1, .len = 2 }, node_to_rotate.branch.right.weights());
    //         try eqStr("CD", node_to_rotate.branch.right.leaf.buf);
    //
    //         const result = try node_to_rotate.rotateRight(a);
    //         try eqDeep(Weights{ .depth = 3, .len = 4 }, result.weights());
    //         try eqDeep(Weights{ .depth = 1, .len = 1 }, result.branch.left.weights());
    //         try eqStr("a", result.branch.left.leaf.buf);
    //         try eqDeep(Weights{ .depth = 2, .len = 3 }, result.branch.right.weights());
    //         try eqStr("B", result.branch.right.branch.left.leaf.buf);
    //         try eqStr("CD", result.branch.right.branch.right.leaf.buf);
    //     }
    // }

    fn rotateLeft(self: *const Node, allocator: Allocator) !*const Node {
        const other = self.branch.right;
        const a = try Node.new(allocator, self.branch.left, other.branch.left);
        const b = try Node.new(allocator, a, other.branch.right);
        return b;
    }
    // test rotateLeft {
    //     const a = idc_if_it_leaks;
    //     {
    //         const acd = try Node.fromString(a, "ACD");
    //         const abcd = try acd.insertChars(a, 1, "B");
    //         const old_root = try abcd.insertChars(a, 4, "E");
    //         const new_root = try old_root.rotateLeft(a);
    //         try eqDeep(Weights{ .depth = 3, .len = 5 }, new_root.weights());
    //         try eqDeep(Weights{ .depth = 2, .len = 2 }, new_root.branch.left.weights());
    //         try eqDeep(Weights{ .depth = 2, .len = 3 }, new_root.branch.right.weights());
    //         try eqStr("A", new_root.branch.left.branch.left.leaf.buf);
    //         try eqStr("B", new_root.branch.left.branch.right.leaf.buf);
    //         try eqStr("CD", new_root.branch.right.branch.left.leaf.buf);
    //         try eqStr("E", new_root.branch.right.branch.right.leaf.buf);
    //     }
    // }

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

    // test insertChars {
    //     const a = idc_if_it_leaks;
    //
    //     { // replace empty Leaf with new Leaf with new content
    //         const root = try Node.fromString(a, "");
    //         const new_root = try root.insertChars(idc_if_it_leaks, 0, "A");
    //         try eqStr("A", new_root.leaf.buf);
    //     }
    //     // { // target_index at start of Leaf
    //     //     const root = try Node.fromString(a, "BCD");
    //     //     const new_root = try root.insertChars(idc_if_it_leaks, 0, "A");
    //     //     try eqDeep(Weights{ .depth = 2, .len = 4 }, new_root.weights());
    //     //     try eqStr("A", new_root.branch.left.leaf.buf);
    //     //     try eqStr("BCD", new_root.branch.right.leaf.buf);
    //     // }
    //     // { // target_index at end of Leaf
    //     //     const root = try Node.fromString(a, "A");
    //     //     const new_root = try root.insertChars(idc_if_it_leaks, 1, "BCD");
    //     //     try eqDeep(Weights{ .depth = 2, .len = 4 }, new_root.weights());
    //     //     try eqStr("A", new_root.branch.left.leaf.buf);
    //     //     try eqStr("BCD", new_root.branch.right.leaf.buf);
    //     // }
    //     // { // target_index at middle of Leaf
    //     //     const root = try Node.fromString(a, "ACD");
    //     //     const new_root = try root.insertChars(idc_if_it_leaks, 1, "B");
    //     //     try eqDeep(Weights{ .depth = 3, .len = 4 }, new_root.weights());
    //     //     try eqDeep(Weights{ .depth = 2, .len = 3 }, new_root.branch.right.weights());
    //     //     try eqStr("A", new_root.branch.left.leaf.buf);
    //     //     try eqStr("B", new_root.branch.right.branch.left.leaf.buf);
    //     //     try eqStr("CD", new_root.branch.right.branch.right.leaf.buf);
    //     // }
    //     //
    //     // {
    //     //     const acd = try Node.fromString(a, "ACD");
    //     //     const abcd = try acd.insertChars(idc_if_it_leaks, 1, "B");
    //     //     const abcde = try abcd.insertChars(idc_if_it_leaks, 4, "E");
    //     //     try eqDeep(Weights{ .depth = 4, .len = 5 }, abcde.weights());
    //     //     try eqDeep(Weights{ .depth = 3, .len = 4 }, abcde.branch.right.weights());
    //     //     try eqDeep(Weights{ .depth = 2, .len = 3 }, abcde.branch.right.branch.right.weights());
    //     //     try eqStr("A", abcde.branch.left.leaf.buf);
    //     //     try eqStr("B", abcde.branch.right.branch.left.leaf.buf);
    //     //     try eqStr("CD", abcde.branch.right.branch.right.branch.left.leaf.buf);
    //     //     try eqStr("E", abcde.branch.right.branch.right.branch.right.leaf.buf);
    //     // }
    // }

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

    ///////////////////////////// Node Info

    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }
    test weights {
        const a = idc_if_it_leaks;
        const node = try Node.new(a, try Leaf.new(a, "one", true, false), try Leaf.new(a, "_two", false, true));
        try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "one" }, node.branch.left.leaf);
        try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "_two" }, node.branch.right.leaf);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 8, .depth = 2 }, node.weights());
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 3, .depth = 1 }, node.branch.left.weights());
        try eqDeep(Weights{ .bols = 0, .eols = 1, .len = 5, .depth = 1 }, node.branch.right.weights());
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
test Node {
    _ = Node{ .leaf = empty_leaf.leaf };
}

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
};

const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(a: Allocator, piece: []const u8, bol: bool, eol: bool) !*const Node {
        if (piece.len == 0) {
            if (!bol and !eol) return &empty_leaf;
            if (bol and !eol) return &empty_bol_leaf;
            if (!bol and eol) return &empty_eol_leaf;
            return &empty_line_leaf;
        }
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = piece, .bol = bol, .eol = eol } };
        return node;
    }

    fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol) len += 1;
        return Weights{
            .bols = if (self.bol) 1 else 0,
            .eols = if (self.eol) 1 else 0,
            .len = @intCast(len),
        };
    }

    fn is_empty(self: *const Leaf) bool {
        return self.buf.len == 0 and !self.bol and !self.eol;
    }
};
test Leaf {
    _ = Leaf{ .buf = "" };
}

const Weights = struct {
    bols: u32 = 0,
    eols: u32 = 0,
    len: u32 = 0,
    depth: u32 = 1,

    fn add(self: *Weights, other: Weights) void {
        self.bols += other.bols;
        self.eols += other.eols;
        self.len += other.len;
        self.depth = @max(self.depth, other.depth);
    }
    test add {
        {
            var w1 = Weights{};
            const w2 = Weights{};
            w1.add(w2);
            try eqDeep(Weights{}, w1);
        }
        {
            var w1 = Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 };
            const w2 = Weights{ .bols = 1, .eols = 1, .len = 3, .depth = 1 };
            w1.add(w2);
            try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 8, .depth = 1 }, w1);
        }
        {
            var w1 = Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 };
            const w2 = Weights{ .bols = 1, .eols = 1, .len = 3, .depth = 2 };
            w1.add(w2);
            try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 8, .depth = 2 }, w1);
        }
    }
};
