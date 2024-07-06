const std = @import("std");

const eqDeep = std.testing.expectEqualDeep;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

const Node = union(enum) {
    node: Branch,
    leaf: Leaf,

    fn weights_sum(self: *const Node) Weights {
        return switch (self.*) {
            .node => |*n| n.weights_sum,
            .leaf => |*l| l.weights(),
        };
    }
};

pub const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
    weights_sum: Weights,
};

const empty_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = false } };
const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = false } };
const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = true } };
const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = true } };

pub const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(a: std.mem.Allocator, piece: []const u8, bol: bool, eol: bool) !*const Node {
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

pub const Weights = struct {
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

test "Node.weights_sum()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const _empty_leaf = try Leaf.new(a, "", false, false);
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, _empty_leaf.weights_sum());

    const hello_bol = try Leaf.new(a, "hello", true, false);
    try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, hello_bol.weights_sum());

    const hello_bol_eol = try Leaf.new(a, "hello", true, true);
    try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, hello_bol_eol.weights_sum());
}

test "Leaf.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const _empty_leaf = try Leaf.new(a, "", false, false);
    try eqDeep(&Node{ .leaf = .{ .buf = "", .bol = false, .eol = false } }, _empty_leaf);

    const hello_leaf = try Leaf.new(a, "hello", true, true);
    try eqDeep(&Node{ .leaf = .{ .buf = "hello", .bol = true, .eol = true } }, hello_leaf);
}

test "Leaf.weights()" {
    const l_empty = Leaf{ .buf = "", .bol = false, .eol = false };
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, l_empty.weights());

    const l1 = Leaf{ .buf = "hello", .bol = true, .eol = true };
    try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, l1.weights());

    const l2 = Leaf{ .buf = "hello", .bol = true, .eol = false };
    try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, l2.weights());
}

test "Weights.add()" {
    var empty_1 = Weights{};
    const empty_2 = Weights{};
    empty_1.add(empty_2);
    try eqDeep(Weights{}, empty_1);

    var w1 = Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 };
    const w2 = Weights{ .bols = 1, .eols = 1, .len = 3, .depth = 1 };
    w1.add(w2);
    try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 8, .depth = 1 }, w1);

    var w3 = Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 };
    const w4 = Weights{ .bols = 1, .eols = 1, .len = 3, .depth = 2 };
    w3.add(w4);
    try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 8, .depth = 2 }, w3);
}
