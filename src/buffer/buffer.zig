const std = @import("std");

const Allocator = std.mem.Allocator;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Buffer = struct {
    external_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    a: Allocator,
    root: Root,

    pub fn create(external_allocator: Allocator, child_allocator: ?Allocator) !*Buffer {
        const self = try external_allocator.create(Buffer);
        self.* = .{
            .external_allocator = external_allocator,
            .arena = std.heap.ArenaAllocator.init(child_allocator orelse std.heap.page_allocator),
            .a = self.arena.allocator(),
            .root = try Node.new(self.a, &empty_leaf, &empty_leaf),
        };
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.arena.deinit();
        self.external_allocator.destroy(self);
    }

    fn load_from_string(self: *const Buffer, s: []const u8) !Root {
        var stream = std.io.fixedBufferStream(s);
        return self.load(stream.reader(), s.len);
    }

    fn load(self: *const Buffer, reader: anytype, size: usize) !Root {
        const buf = try self.a.alloc(u8, size);

        const read_size = try reader.read(buf);
        if (read_size != size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) @panic("unexpected data in final read");

        const leaves = try _create_leaves(self.a, buf);
        return Node.merge_in_place(self.a, leaves);
    }

    fn _create_leaves(a: std.mem.Allocator, buf: []const u8) ![]Node {
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

        if (leaves.len != cur_leaf + 1) return error.Unexpected;
        return leaves;
    }
};

const Root = *const Node;

const Node = union(enum) {
    node: Branch,
    leaf: Leaf,

    fn weights_sum(self: *const Node) Weights {
        return switch (self.*) {
            .node => |*n| n.weights_sum,
            .leaf => |*l| l.weights(),
        };
    }

    fn new(a: Allocator, l: *const Node, r: *const Node) !*const Node {
        const node = try a.create(Node);
        const left_ws = l.weights_sum();
        const right_ws = r.weights_sum();

        var ws = Weights{};
        ws.add(left_ws);
        ws.add(right_ws);
        ws.depth += 1;

        node.* = .{ .node = .{ .left = l, .right = r, .weights = left_ws, .weights_sum = ws } };
        return node;
    }

    fn merge_in_place(a: Allocator, leaves: []const Node) !Root {
        if (leaves.len == 1) return &leaves[0];
        if (leaves.len == 2) return Node.new(a, &leaves[0], &leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try merge_in_place(a, leaves[0..mid]), try merge_in_place(a, leaves[mid..]));
    }
};

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
    weights_sum: Weights,
};

const empty_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = false } };
const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = false } };
const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = true } };
const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = true } };

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

    inline fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol) len += 1;
        return .{
            .bols = if (self.bol) 1 else 0,
            .eols = if (self.eol) 1 else 0,
            .len = @intCast(len),
        };
    }
};

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
};

//////////////////////////////////////////////////////////////////////////////////////////////

test "Buffer.create() & Buffer.deinit()" {
    const empty_buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer empty_buffer.deinit();

    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_buffer.root.weights_sum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.left.weights_sum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.right.weights_sum());
}

test "Buffer.load_from_string()" {
    const buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer buffer.deinit();

    {
        const root = try buffer.load_from_string("ayaya");
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, root.weights_sum());
        try eqStr("ayaya", root.leaf.buf);
    }

    {
        const root = try buffer.load_from_string("hello\nworld");
        try eqDeep(Weights{ .bols = 2, .eols = 1, .len = 11, .depth = 2 }, root.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, root.node.right.weights_sum());
        try eqStr("hello", root.node.left.leaf.buf);
        try eqStr("world", root.node.right.leaf.buf);
    }
}

test "Buffer._create_leaves()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const str = "hello";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._create_leaves(a, str));
    }

    {
        const str = "hello\nworld";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "world", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._create_leaves(a, str));
    }

    {
        const str = "hello\nfrom\nthe\nother side";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "from", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "the", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "other side", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._create_leaves(a, str));
    }
}

test "Node.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_node = try Node.new(a, &empty_leaf, &empty_leaf);
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_node.weights_sum());
}

test "Node.merge_in_place()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
        };

        const root = try Node.merge_in_place(a, &leaves);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.weights_sum());
    }

    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "mars", .bol = true, .eol = true } },
        };

        const root = try Node.merge_in_place(a, &leaves);
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 11, .depth = 2 }, root.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.weights_sum());
    }

    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "from", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "mars", .bol = true, .eol = true } },
        };

        const root = try Node.merge_in_place(a, &leaves);
        try eqDeep(Weights{ .bols = 3, .eols = 3, .len = 16, .depth = 3 }, root.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weights_sum());
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 10, .depth = 2 }, root.node.right.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.node.left.weights_sum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.node.right.weights_sum());
        try eqStr("hello", root.node.left.leaf.buf);
        try eqStr("from", root.node.right.node.left.leaf.buf);
        try eqStr("mars", root.node.right.node.right.leaf.buf);
    }

    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "from", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "the", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "other side", .bol = true, .eol = true } },
        };

        const root = try Node.merge_in_place(a, &leaves);
        try eqDeep(Weights{ .bols = 4, .eols = 4, .len = 26, .depth = 3 }, root.weights_sum());

        const root_left = root.node.left;
        const root_right = root.node.right;
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 11, .depth = 2 }, root_left.weights_sum());
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 15, .depth = 2 }, root_right.weights_sum());

        const hello = root_left.node.left;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, hello.weights_sum());
        try eqStr("hello", hello.leaf.buf);

        const from = root_left.node.right;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, from.weights_sum());
        try eqStr("from", from.leaf.buf);

        const the = root_right.node.left;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 4, .depth = 1 }, the.weights_sum());
        try eqStr("the", the.leaf.buf);

        const other_side = root_right.node.right;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 11, .depth = 1 }, other_side.weights_sum());
        try eqStr("other side", other_side.leaf.buf);
    }
}

test "Node.weights_sum()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const leaf = try Leaf.new(a, "", false, false);
        try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, leaf.weights_sum());
    }

    {
        const leaf = try Leaf.new(a, "hello", true, false);
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, leaf.weights_sum());
    }

    {
        const leaf = try Leaf.new(a, "hello", true, true);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, leaf.weights_sum());
    }
}

test "Leaf.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const leaf = try Leaf.new(a, "", false, false);
        try eqDeep(&Node{ .leaf = .{ .buf = "", .bol = false, .eol = false } }, leaf);
    }

    {
        const leaf = try Leaf.new(a, "hello", true, true);
        try eqDeep(&Node{ .leaf = .{ .buf = "hello", .bol = true, .eol = true } }, leaf);
    }
}

test "Leaf.weights()" {
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = false };
        try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, leaf.weights());
    }

    {
        const leaf = Leaf{ .buf = "hello", .bol = true, .eol = true };
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, leaf.weights());
    }

    {
        const leaf = Leaf{ .buf = "hello", .bol = true, .eol = false };
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, leaf.weights());
    }
}

test "Weights.add()" {
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
