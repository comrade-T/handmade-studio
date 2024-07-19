const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;

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

    pub fn toArrayList(self: *Buffer, a: Allocator) !std.ArrayList(u8) {
        var s = try ArrayList(u8).initCapacity(a, self.root.weightsSum().len);
        try self.root.store(s.writer());
        return s;
    }

    pub fn loadFromString(self: *const Buffer, s: []const u8) !Root {
        var stream = std.io.fixedBufferStream(s);
        return self.load(stream.reader(), s.len);
    }

    fn load(self: *const Buffer, reader: anytype, size: usize) !Root {
        const buf = try self.a.alloc(u8, size);

        const read_size = try reader.read(buf);
        if (read_size != size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) @panic("unexpected data in final read");

        const leaves = try _createLeaves(self.a, buf);
        return Node.mergeInPlace(self.a, leaves);
    }

    fn _createLeaves(a: std.mem.Allocator, buf: []const u8) ![]Node {
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

    const GetLineCtx = struct {
        result_list: *ArrayList(u8),
        fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            ctx.result_list.appendSlice(leaf.buf) catch |e| return Walker{ .err = e };
            return if (leaf.eol) Walker.stop else Walker.keep_walking;
        }
    };

    fn getLine(self: *const Buffer, line: usize, result_list: *ArrayList(u8)) !void {
        if (line + 1 > self.root.weightsSum().bols) return error.NotFound;
        var walk_ctx: GetLineCtx = .{ .result_list = result_list };
        const walk_result = self.root.walkLine(line, GetLineCtx.walker, &walk_ctx);
        if (walk_result.err) |e| return e;
        return if (!walk_result.found) error.NotFound;
    }
};

const Walker = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    const keep_walking = Walker{ .keep_walking = true };
    const stop = Walker{ .keep_walking = false };
    const found = Walker{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) Walker;
};

const WalkerMut = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    replace: ?Root = null,

    const keep_walking = WalkerMut{ .keep_walking = true };
    const stop = WalkerMut{ .keep_walking = false };
    const found = WalkerMut{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkerMut;
};

const Root = *const Node;

const Node = union(enum) {
    node: Branch,
    leaf: Leaf,

    fn weightsSum(self: *const Node) Weights {
        return switch (self.*) {
            .node => |*branch| branch.weights_sum,
            .leaf => |*leaf| leaf.weights(),
        };
    }

    fn new(a: Allocator, l: *const Node, r: *const Node) !*const Node {
        const node = try a.create(Node);
        const left_ws = l.weightsSum();
        const right_ws = r.weightsSum();

        var ws = Weights{};
        ws.add(left_ws);
        ws.add(right_ws);
        ws.depth += 1;

        node.* = .{ .node = .{ .left = l, .right = r, .weights = left_ws, .weights_sum = ws } };
        return node;
    }

    fn isEmpty(self: *const Node) bool {
        return switch (self.*) {
            .node => |*branch| branch.left.isEmpty() and branch.right.isEmpty(),
            .leaf => |*l| if (self == &empty_leaf) true else l.isEmpty(),
        };
    }

    fn store(self: *const Node, writer: anytype) !void {
        switch (self.*) {
            .node => |*branch| {
                try branch.left.store(writer);
                try branch.right.store(writer);
            },
            .leaf => |*leaf| {
                _ = try writer.write(leaf.buf);
                if (leaf.eol) _ = try writer.write("\n");
            },
        }
    }

    fn mergeInPlace(a: Allocator, leaves: []const Node) !Root {
        if (leaves.len == 1) return &leaves[0];
        if (leaves.len == 2) return Node.new(a, &leaves[0], &leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try mergeInPlace(a, leaves[0..mid]), try mergeInPlace(a, leaves[mid..]));
    }

    fn walkLine(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque) Walker {
        switch (self.*) {
            .node => |*branch| {
                const left_bols = branch.weights.bols;
                if (line >= left_bols) return branch.right.walkLine(line - left_bols, f, ctx);
                const left_result = branch.left.walkLine(line, f, ctx);
                const right_result = if (left_result.found and left_result.keep_walking) branch.right.walk(f, ctx) else Walker{};
                return branch.mergeWalkResults(left_result, right_result);
            },
            .leaf => |*leaf| {
                if (line == 0) {
                    var result = f(ctx, leaf);
                    if (result.err) |_| return result;
                    result.found = true;
                    return result;
                }
                return Walker.keep_walking;
            },
        }
    }

    fn walk(self: *const Node, f: Walker.F, ctx: *anyopaque) Walker {
        switch (self.*) {
            .node => |*branch| {
                const left = branch.left.walk(f, ctx);
                if (!left.keep_walking) {
                    var result = Walker{};
                    result.err = left.err;
                    result.found = left.found;
                    return result;
                }
                const right = branch.right.walk(f, ctx);
                return branch.mergeWalkResults(left, right);
            },
            .leaf => |*l| return f(ctx, l),
        }
    }

    fn walkLineMut(self: *const Node, a: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols) {
                    const right = node.right.walkLineMut(a, line - left_bols, f, ctx);
                    if (right.replace) |replacement| {
                        return WalkerMut{
                            .err = right.err,
                            .found = right.found,
                            .keep_walking = right.keep_walking,
                            .replace = if (replacement.isEmpty())
                                node.left
                            else
                                Node.new(a, node.left, replacement) catch |e| return WalkerMut{ .err = e },
                        };
                    }
                    return right;
                }
                const left = node.left.walkLineMut(a, line, f, ctx);
                const right = if (left.found and left.keep_walking) node.right.walkMut(a, f, ctx) else WalkerMut{};
                return node.mergeWalkResultsMut(a, left, right);
            },
            .leaf => |*l| {
                if (line == 0) {
                    var result = f(ctx, l);
                    if (result.err) |_| {
                        result.replace = null;
                        return result;
                    }
                    result.found = true;
                    return result;
                }
                return WalkerMut.keep_walking;
            },
        }
    }

    fn walkMut(self: *const Node, a: Allocator, f: WalkerMut.F, ctx: *anyopaque) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walkMut(a, f, ctx);
                if (!left.keep_walking) {
                    return WalkerMut{
                        .err = left.err,
                        .found = left.found,
                        .replace = if (left.replace) |replacement|
                            Node.new(a, replacement, node.right) catch |e| return WalkerMut{ .err = e }
                        else
                            null,
                    };
                }
                const right = node.right.walkMut(a, f, ctx);
                return node.mergeWalkResultsMut(a, left, right);
            },
            .leaf => |*l| return f(ctx, l),
        }
    }
};

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
    weights_sum: Weights,

    fn mergeWalkResults(_: *const Branch, left: Walker, right: Walker) Walker {
        var result = Walker{};
        result.err = if (left.err) |_| left.err else right.err;
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }

    fn mergeWalkResultsMut(self: *const Branch, a: Allocator, left: WalkerMut, right: WalkerMut) WalkerMut {
        return WalkerMut{
            .err = if (left.err) |_| left.err else right.err,
            .keep_walking = left.keep_walking and right.keep_walking,
            .found = left.found or right.found,
            .replace = if (left.replace == null and right.replace == null)
                null
            else
                self._mergeReplacements(a, left, right) catch |e| return WalkerMut{ .err = e },
        };
    }

    fn _mergeReplacements(self: *const Branch, a: std.mem.Allocator, left: WalkerMut, right: WalkerMut) !*const Node {
        const new_left = if (left.replace) |p| p else self.left;
        const new_right = if (right.replace) |p| p else self.right;

        if (new_left.isEmpty()) return new_right;
        if (new_right.isEmpty()) return new_left;

        return Node.new(a, new_left, new_right);
    }
};

const empty_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = false } };
const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = false } };
const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .bol = false, .eol = true } };
const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .bol = true, .eol = true } };

const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,

    fn new(a: Allocator, content: []const u8, bol: bool, eol: bool) !*const Node {
        if (content.len == 0) {
            if (!bol and !eol) return &empty_leaf;
            if (bol and !eol) return &empty_bol_leaf;
            if (!bol and eol) return &empty_eol_leaf;
            return &empty_line_leaf;
        }
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = content, .bol = bol, .eol = eol } };
        return node;
    }

    inline fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol) len += 1;
        return Weights{
            .bols = if (self.bol) 1 else 0,
            .eols = if (self.eol) 1 else 0,
            .len = @intCast(len),
        };
    }

    inline fn isEmpty(self: *const Leaf) bool {
        return self.buf.len == 0 and !self.bol and !self.eol;
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

///////////////////////////// Buffer

test "Buffer.create() & Buffer.deinit()" {
    const empty_buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer empty_buffer.deinit();

    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_buffer.root.weightsSum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.left.weightsSum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.right.weightsSum());
}

fn testBufferGetLine(a: std.mem.Allocator, buf: *Buffer, line: usize, expected: []const u8) !void {
    var result = ArrayList(u8).init(a);
    defer result.deinit();
    try buf.getLine(line, &result);
    try std.testing.expectEqualStrings(expected, result.items);
}

test "Buffer.getLine()" {
    const a = std.testing.allocator;
    var buf = try Buffer.create(a, a);
    defer buf.deinit();
    {
        buf.root = try buf.loadFromString("ayaya");
        try testBufferGetLine(a, buf, 0, "ayaya");
        try shouldErr(error.NotFound, testBufferGetLine(a, buf, 1, ""));
    }
    {
        buf.root = try buf.loadFromString("hello\nworld");
        try testBufferGetLine(a, buf, 0, "hello");
        try testBufferGetLine(a, buf, 1, "world");
        try shouldErr(error.NotFound, testBufferGetLine(a, buf, 2, ""));
    }
    {
        buf.root = try buf.loadFromString("안녕하세요!\nHello there 👋!");
        try testBufferGetLine(a, buf, 0, "안녕하세요!");
        try testBufferGetLine(a, buf, 1, "Hello there 👋!");
        try shouldErr(error.NotFound, testBufferGetLine(a, buf, 2, ""));
    }
}

test "Buffer.loadFromString()" {
    const buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer buffer.deinit();
    {
        const root = try buffer.loadFromString("ayaya");
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, root.weightsSum());
        try eqStr("ayaya", root.leaf.buf);
    }
    {
        const root = try buffer.loadFromString("hello\nworld");
        try eqDeep(Weights{ .bols = 2, .eols = 1, .len = 11, .depth = 2 }, root.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, root.node.right.weightsSum());
        try eqStr("hello", root.node.left.leaf.buf);
        try eqStr("world", root.node.right.leaf.buf);
    }
    {
        const source =
            \\one
            \\two two
            \\three three three
            \\four four four four
        ;
        const root = try buffer.loadFromString(source);
        try eqDeep(Weights{ .bols = 4, .eols = 3, .len = 49, .depth = 3 }, root.weightsSum());
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 12, .depth = 2 }, root.node.left.node.weights_sum);
        try eqDeep(Weights{ .bols = 2, .eols = 1, .len = 37, .depth = 2 }, root.node.right.node.weights_sum);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 4, .depth = 1 }, root.node.left.node.left.leaf.weights());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 8, .depth = 1 }, root.node.left.node.right.leaf.weights());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 18, .depth = 1 }, root.node.right.node.left.leaf.weights());
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 19, .depth = 1 }, root.node.right.node.right.leaf.weights());
    }
}

test "Buffer._createLeaves()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const str = "hello";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._createLeaves(a, str));
    }
    {
        const str = "hello\nworld";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "world", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._createLeaves(a, str));
    }
    {
        const str = "hello\nfrom\nthe\nother side";
        const expected = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "from", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "the", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "other side", .bol = true, .eol = false } },
        };
        try eqDeep(&expected, try Buffer._createLeaves(a, str));
    }
}

///////////////////////////// Node

test "Node.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty_node = try Node.new(a, &empty_leaf, &empty_leaf);
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_node.weightsSum());
}

fn testNodeStore(a: std.mem.Allocator, root: Root, expected: []const u8) !void {
    var s = try ArrayList(u8).initCapacity(a, root.weightsSum().len);
    defer s.deinit();
    try root.store(s.writer());
    try eqStr(expected, s.items);
}

test "Node.store()" {
    const a = std.testing.allocator;
    const buffer = try Buffer.create(a, a);
    defer buffer.deinit();

    {
        const content = "hello\nworld";
        const root = try buffer.loadFromString(content);
        try testNodeStore(a, root, content);
    }
    {
        const content = "one two";
        const root = try buffer.loadFromString(content);
        try testNodeStore(a, root, content);
    }
    {
        const content = [_]u8{ 'A', 'A', 'A', 10 } ** 1_000;
        const root = try buffer.loadFromString(&content);
        try testNodeStore(a, root, &content);
    }
}

fn walkThroughNodeToGetAllLeaves(a: Allocator, node: Root) ![]*const Leaf {
    const Ctx = struct {
        list: *ArrayList(*const Leaf),
        fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            ctx.list.append(leaf) catch |e| return Walker{ .err = e };
            return Walker.keep_walking;
        }
    };

    var list = std.ArrayList(*const Leaf).init(a);
    var walk_ctx: Ctx = .{ .list = &list };
    const walk_result = node.walk(Ctx.walker, &walk_ctx);

    if (walk_result.err) |e| return e;
    return try list.toOwnedSlice();
}

test "Node.walk()" {
    const a = std.testing.allocator;
    const buffer = try Buffer.create(a, a);
    defer buffer.deinit();

    {
        const root = try buffer.loadFromString("hello\nfrom\nthe\nother\nside");
        const leaves = try walkThroughNodeToGetAllLeaves(a, root);
        defer a.free(leaves);

        try eqDeep(Leaf{ .buf = "hello", .bol = true, .eol = true }, leaves[0].*);
        try eqDeep(Leaf{ .buf = "from", .bol = true, .eol = true }, leaves[1].*);
        try eqDeep(Leaf{ .buf = "the", .bol = true, .eol = true }, leaves[2].*);
        try eqDeep(Leaf{ .buf = "other", .bol = true, .eol = true }, leaves[3].*);
        try eqDeep(Leaf{ .buf = "side", .bol = true, .eol = false }, leaves[4].*);
    }
}

test "Node.mergeInPlace()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
        };
        const root = try Node.mergeInPlace(a, &leaves);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.weightsSum());
    }
    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "mars", .bol = true, .eol = true } },
        };
        const root = try Node.mergeInPlace(a, &leaves);
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 11, .depth = 2 }, root.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.weightsSum());
    }
    {
        const leaves = [_]Node{
            Node{ .leaf = Leaf{ .buf = "hello", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "from", .bol = true, .eol = true } },
            Node{ .leaf = Leaf{ .buf = "mars", .bol = true, .eol = true } },
        };
        const root = try Node.mergeInPlace(a, &leaves);
        try eqDeep(Weights{ .bols = 3, .eols = 3, .len = 16, .depth = 3 }, root.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, root.node.left.weightsSum());
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 10, .depth = 2 }, root.node.right.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.node.left.weightsSum());
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, root.node.right.node.right.weightsSum());
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

        const root = try Node.mergeInPlace(a, &leaves);
        try eqDeep(Weights{ .bols = 4, .eols = 4, .len = 26, .depth = 3 }, root.weightsSum());

        const root_left = root.node.left;
        const root_right = root.node.right;
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 11, .depth = 2 }, root_left.weightsSum());
        try eqDeep(Weights{ .bols = 2, .eols = 2, .len = 15, .depth = 2 }, root_right.weightsSum());

        const hello = root_left.node.left;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, hello.weightsSum());
        try eqStr("hello", hello.leaf.buf);

        const from = root_left.node.right;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 5, .depth = 1 }, from.weightsSum());
        try eqStr("from", from.leaf.buf);

        const the = root_right.node.left;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 4, .depth = 1 }, the.weightsSum());
        try eqStr("the", the.leaf.buf);

        const other_side = root_right.node.right;
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 11, .depth = 1 }, other_side.weightsSum());
        try eqStr("other side", other_side.leaf.buf);
    }
}

///////////////////////////// Leaf

test "Leaf.new()" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const leaf = try Leaf.new(a, "", false, false);
        try eqDeep(&Node{ .leaf = .{ .buf = "", .bol = false, .eol = false } }, leaf);
        try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, leaf.leaf.weights());
    }
    {
        const leaf = try Leaf.new(a, "hello", true, true);
        try eqDeep(&Node{ .leaf = .{ .buf = "hello", .bol = true, .eol = true } }, leaf);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, leaf.leaf.weights());
    }
    {
        const leaf = try Leaf.new(a, "안녕", true, true);
        try eqDeep(&Node{ .leaf = .{ .buf = "안녕", .bol = true, .eol = true } }, leaf);
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 7, .depth = 1 }, leaf.leaf.weights());
    }
}

test "Leaf.weights()" {
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = false };
        try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, leaf.weights());
    }
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = true };
        try eqDeep(Weights{ .bols = 0, .eols = 1, .len = 1, .depth = 1 }, leaf.weights());
    }
    {
        const leaf = Leaf{ .buf = "hello", .bol = true, .eol = true };
        try eqDeep(Weights{ .bols = 1, .eols = 1, .len = 6, .depth = 1 }, leaf.weights());
    }
    {
        const leaf = Leaf{ .buf = "hello", .bol = true, .eol = false };
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 5, .depth = 1 }, leaf.weights());
    }
    {
        const leaf = Leaf{ .buf = "안녕", .bol = true, .eol = false };
        try eqDeep(Weights{ .bols = 1, .eols = 0, .len = 6, .depth = 1 }, leaf.weights());
    }
}

test "Leaf.isEmpty()" {
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = false };
        try eq(true, leaf.isEmpty());
    }
    {
        const leaf = Leaf{ .buf = "hi!", .bol = false, .eol = false };
        try eq(false, leaf.isEmpty());
    }
    {
        const leaf = Leaf{ .buf = "", .bol = true, .eol = false };
        try eq(false, leaf.isEmpty());
    }
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = true };
        try eq(false, leaf.isEmpty());
    }
}

///////////////////////////// Weights

test Weights {
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
