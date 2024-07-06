const std = @import("std");

const Allocator = std.mem.Allocator;
const eqDeep = std.testing.expectEqualDeep;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

const Buffer = struct {
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

test Buffer {
    const empty_buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer empty_buffer.deinit();

    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_buffer.root.weights_sum());
}

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

test "Node.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_node = try Node.new(a, &empty_leaf, &empty_leaf);
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_node.weights_sum());
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
