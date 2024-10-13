const std = @import("std");
const rc = @import("zigrc");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqDeep = std.testing.expectEqualDeep;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

const RcNode = rc.Rc(Node);
const Node = union(enum) {
    branch: Branch,
    leaf: Leaf,

    fn new(a: Allocator, left: RcNode, right: RcNode) !RcNode {
        var w = Weights{};
        w.add(left.value.weights());
        w.add(right.value.weights());
        w.depth += 1;
        return try RcNode.init(a, .{
            .branch = .{ .left = left, .right = right, .weights = w },
        });
    }

    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }

    ///////////////////////////// Release

    fn releaseChildrenRecursive(self: *const Node) void {
        if (self.* == .leaf) return;
        self.branch.left.value.releaseChildrenRecursive();
        self.branch.left.release();
        self.branch.right.value.releaseChildrenRecursive();
        self.branch.right.release();
    }

    ///////////////////////////// Load

    fn fromString(a: Allocator, arena: *ArenaAllocator, source: []const u8, first_bol: bool) !RcNode {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, arena, stream.reader(), source.len, first_bol);
    }

    test fromString {
        // without bol
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            const root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld", false);
            defer {
                root.value.releaseChildrenRecursive();
                root.release();
                content_arena.deinit();
            }
            try eqStr(
                \\2 1/11
                \\  1 `hello` |E
                \\  1 B| `world`
            , try root.value.debugStr(idc_if_it_leaks));
        }

        // with bol
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            const root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld", true);
            defer {
                root.value.releaseChildrenRecursive();
                root.release();
                content_arena.deinit();
            }
            try eqStr(
                \\2 2/11
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try root.value.debugStr(idc_if_it_leaks));
        }
    }

    fn fromReader(a: Allocator, arena: *ArenaAllocator, reader: anytype, buffer_size: usize, first_bol: bool) !RcNode {
        const buf = try arena.allocator().alloc(u8, buffer_size);

        const read_size = try reader.read(buf);
        if (read_size != buffer_size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) return error.Unexpected;

        var leaves = try createLeavesByNewLine(a, buf);
        defer a.free(leaves);
        leaves[0].value.leaf.bol = first_bol;
        return try mergeLeaves(a, leaves);
    }

    fn createLeavesByNewLine(a: std.mem.Allocator, buf: []const u8) ![]RcNode {
        if (eql(u8, buf, "\n")) {
            var leaves = try a.alloc(RcNode, 1);
            leaves[0] = try Leaf.new(a, "", false, true);
            return leaves;
        }

        var leaf_count: usize = 1;
        for (0..buf.len) |i| {
            if (buf[i] == '\n') leaf_count += 1;
        }

        var leaves = try a.alloc(RcNode, leaf_count);
        var cur_leaf: usize = 0;
        var b: usize = 0;
        for (0..buf.len) |i| {
            if (buf[i] == '\n') {
                const line = buf[b..i];
                leaves[cur_leaf] = try Leaf.new(a, line, true, true);
                cur_leaf += 1;
                b = i + 1;
            }
        }

        const rest = buf[b..];
        leaves[cur_leaf] = try Leaf.new(a, rest, true, false);

        leaves[0].value.leaf.bol = false; // always make first Leaf NOT a .bol

        if (leaves.len != cur_leaf + 1) return error.Unexpected;
        return leaves;
    }

    test createLeavesByNewLine {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "" }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "\n");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "" }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "hello\nworld");
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "hello" }, leaves[0].value.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world" }, leaves[1].value.leaf);
        }
    }

    fn mergeLeaves(a: Allocator, leaves: []RcNode) !RcNode {
        if (leaves.len == 1) return leaves[0];
        if (leaves.len == 2) return Node.new(a, leaves[0], leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try mergeLeaves(a, leaves[0..mid]), try mergeLeaves(a, leaves[mid..]));
    }

    ///////////////////////////// Debug Print

    fn debugStr(self: *const Node, a: Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(a);
        try self._buildDebugStr(a, &result, 0);
        return try result.toOwnedSlice();
    }

    fn _buildDebugStr(self: *const Node, a: Allocator, result: *std.ArrayList(u8), indent_level: usize) !void {
        if (indent_level > 0) try result.append('\n');
        for (0..indent_level) |_| try result.append(' ');
        switch (self.*) {
            .branch => |branch| {
                const content = try std.fmt.allocPrint(a, "{d} {d}/{d}", .{ branch.weights.depth, branch.weights.bols, branch.weights.len });
                defer a.free(content);
                try result.appendSlice(content);
                try branch.left.value._buildDebugStr(a, result, indent_level + 2);
                try branch.right.value._buildDebugStr(a, result, indent_level + 2);
            },
            .leaf => |leaf| {
                const bol = if (leaf.bol) "B| " else "";
                const eol = if (leaf.eol) " |E" else "";
                const leaf_content = if (leaf.buf.len > 0) leaf.buf else "";
                const content = try std.fmt.allocPrint(a, "1 {s}`{s}`{s}", .{ bol, leaf_content, eol });
                defer a.free(content);
                try result.appendSlice(content);
            },
        }
    }
};

const Branch = struct {
    left: RcNode,
    right: RcNode,
    weights: Weights,
};

const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(a: Allocator, source: []const u8, bol: bool, eol: bool) !RcNode {
        return try RcNode.init(a, .{
            .leaf = .{ .buf = source, .bol = bol, .eol = eol },
        });
    }

    test new {
        const leaf = try Leaf.new(testing_allocator, "hello", false, false);
        defer leaf.release();

        try eq(1, leaf.strongCount());
        try eq(0, leaf.weakCount());
        try eqStr("hello", leaf.value.leaf.buf);
        try eq(false, leaf.value.leaf.bol);
        try eq(false, leaf.value.leaf.eol);
    }

    fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol) len += 1;
        return Weights{
            .bols = if (self.bol) 1 else 0,
            .len = @intCast(len),
        };
    }

    fn isEmpty(self: *const Leaf) bool {
        return self.buf.len == 0 and !self.bol and !self.eol;
    }
};

const Weights = struct {
    bols: u32 = 0,
    len: u32 = 0,
    depth: u32 = 1,

    fn add(self: *Weights, other: Weights) void {
        self.bols += other.bols;
        self.len += other.len;
        self.depth = @max(self.depth, other.depth);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDecls(Node);
    std.testing.refAllDecls(Leaf);
}
