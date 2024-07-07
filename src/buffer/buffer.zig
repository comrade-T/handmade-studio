const std = @import("std");
const code_point = @import("code_point");

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

    fn get_line(self: *const Buffer, line: usize, result_list: *ArrayList(u8)) !void {
        const GetLineCtx = struct {
            result_list: *ArrayList(u8),
            fn walker(ctx_: *anyopaque, leaf: *const Leaf) Walker {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.result_list.appendSlice(leaf.buf) catch |e| return Walker{ .err = e };
                return if (!leaf.eol) Walker.keep_walking else Walker.stop;
            }
        };

        var walk_ctx: GetLineCtx = .{ .result_list = result_list };
        const walk_result = self.root.walk_line(line, GetLineCtx.walker, &walk_ctx);
        if (walk_result.err) |e| return e;
        return if (!walk_result.found) error.NotFound;
    }

    const InsertCharsCtx = struct {
        a: Allocator,
        col: usize,
        s: []const u8,
        eol: bool,

        fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkerMut {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            const leaf_num_of_chars = num_of_chars(leaf.buf);

            if (ctx.col == 0) {
                const left = Leaf.new(ctx.a, ctx.s, leaf.bol, ctx.eol) catch |e| return .{ .err = e };
                const right = Leaf.new(ctx.a, leaf.buf, ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                return WalkerMut{ .replace = Node.new(ctx.a, left, right) catch |e| return .{ .err = e } };
            }

            if (ctx.col == leaf_num_of_chars) {
                if (leaf.eol and ctx.eol and ctx.s.len == 0) {
                    const left = Leaf.new(ctx.a, leaf.buf, leaf.bol, true) catch |e| return .{ .err = e };
                    const right = Leaf.new(ctx.a, ctx.s, true, true) catch |e| return .{ .err = e };
                    return WalkerMut{ .replace = Node.new(ctx.a, left, right) catch |e| return .{ .err = e } };
                }

                const left = Leaf.new(ctx.a, leaf.buf, leaf.bol, false) catch |e| return .{ .err = e };

                if (ctx.eol) {
                    const middle = Leaf.new(ctx.a, ctx.s, false, ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(ctx.a, "", ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    const middle_right = Node.new(ctx.a, middle, right) catch |e| return .{ .err = e };
                    return WalkerMut{ .replace = Node.new(ctx.a, left, middle_right) catch |e| return .{ .err = e } };
                }

                const right = Leaf.new(ctx.a, ctx.s, false, leaf.eol) catch |e| return .{ .err = e };
                return WalkerMut{ .replace = Node.new(ctx.a, left, right) catch |e| return .{ .err = e } };
            }

            if (ctx.col < leaf_num_of_chars) {
                const pos = byte_count_for_range(leaf.buf, 0, ctx.col);

                if (ctx.eol and ctx.s.len == 0) {
                    const left = Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, ctx.eol) catch |e| return .{ .err = e };
                    const right = Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                    return WalkerMut{ .replace = Node.new(ctx.a, left, right) catch |e| return .{ .err = e } };
                }

                const left = Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, false) catch |e| return .{ .err = e };
                const middle = Leaf.new(ctx.a, ctx.s, false, ctx.eol) catch |e| return .{ .err = e };
                const right = Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol) catch |e| return .{ .err = e };
                const middle_right = Node.new(ctx.a, middle, right) catch |e| return .{ .err = e };
                return WalkerMut{ .replace = Node.new(ctx.a, left, middle_right) catch |e| return .{ .err = e } };
            }

            ctx.col -= leaf_num_of_chars;
            return if (leaf.eol) WalkerMut.stop else WalkerMut.keep_walking;
        }
    };

    pub fn insert_chars(
        self: *const Buffer,
        a: Allocator,
        line_: usize,
        col_: usize,
        s: []const u8,
    ) !struct { usize, usize, Root } {
        if (s.len == 0) return error.Stop;

        var root = self.root;
        var rest = try a.dupe(u8, s);
        var chunk = rest;
        var line = line_;
        var col = col_;
        var need_eol = false;

        while (rest.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |eol| {
                chunk = rest[0..eol];
                rest = rest[eol + 1 ..];
                need_eol = true;
            } else {
                chunk = rest;
                rest = &[_]u8{};
                need_eol = false;
            }

            var ctx: InsertCharsCtx = .{ .a = a, .col = col, .s = chunk, .eol = need_eol };
            const walk_result = root.walk_line_mut(a, line, InsertCharsCtx.walker, &ctx);
            if (walk_result.err) |e| return e;
            if (!walk_result.found) return error.NotFound;
            if (walk_result.replace) |new_root| root = new_root;

            if (need_eol) {
                line += 1;
                col = 0;
                continue;
            }
            col += num_of_chars(chunk);
        }

        return .{ line, col, root };
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

pub const WalkerMut = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    replace: ?Root = null,

    pub const keep_walking = WalkerMut{ .keep_walking = true };
    pub const stop = WalkerMut{ .keep_walking = false };
    pub const found = WalkerMut{ .found = true };

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkerMut;
};

const Root = *const Node;

const Node = union(enum) {
    node: Branch,
    leaf: Leaf,

    fn weights_sum(self: *const Node) Weights {
        return switch (self.*) {
            .node => |*branch| branch.weights_sum,
            .leaf => |*leaf| leaf.weights(),
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

    fn is_empty(self: *const Node) bool {
        return switch (self.*) {
            .node => |*branch| branch.left.is_empty() and branch.right.is_empty(),
            .leaf => |*l| if (self == &empty_leaf) true else l.is_empty(),
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

    fn merge_in_place(a: Allocator, leaves: []const Node) !Root {
        if (leaves.len == 1) return &leaves[0];
        if (leaves.len == 2) return Node.new(a, &leaves[0], &leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try merge_in_place(a, leaves[0..mid]), try merge_in_place(a, leaves[mid..]));
    }

    fn walk_line(self: *const Node, line: usize, f: Walker.F, ctx: *anyopaque) Walker {
        switch (self.*) {
            .node => |*branch| {
                const left_bols = branch.weights.bols;
                if (line >= left_bols) return branch.right.walk_line(line - left_bols, f, ctx);
                const left_result = branch.left.walk_line(line, f, ctx);
                const right_result = if (left_result.found and left_result.keep_walking) branch.right.walk(f, ctx) else Walker{};
                return branch.merge_walk_results(left_result, right_result);
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
                return branch.merge_walk_results(left, right);
            },
            .leaf => |*l| return f(ctx, l),
        }
    }

    fn walk_line_mut(self: *const Node, a: Allocator, line: usize, f: WalkerMut.F, ctx: *anyopaque) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left_bols = node.weights.bols;
                if (line >= left_bols) {
                    const right = node.right.walk_line_mut(a, line - left_bols, f, ctx);
                    if (right.replace) |replacement| {
                        return WalkerMut{
                            .err = right.err,
                            .found = right.found,
                            .keep_walking = right.keep_walking,
                            .replace = if (replacement.is_empty())
                                node.left
                            else
                                Node.new(a, node.left, replacement) catch |e| return WalkerMut{ .err = e },
                        };
                    }
                    return right;
                }
                const left = node.left.walk_line_mut(a, line, f, ctx);
                const right = if (left.found and left.keep_walking) node.right.walk_mut(a, f, ctx) else WalkerMut{};
                return node.merge_walk_results_mut(a, left, right);
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

    fn walk_mut(self: *const Node, a: Allocator, f: WalkerMut.F, ctx: *anyopaque) WalkerMut {
        switch (self.*) {
            .node => |*node| {
                const left = node.left.walk_mut(a, f, ctx);
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
                const right = node.right.walk_mut(a, f, ctx);
                return node.merge_walk_results_mut(a, left, right);
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

    fn merge_walk_results(_: *const Branch, left: Walker, right: Walker) Walker {
        var result = Walker{};
        result.err = if (left.err) |_| left.err else right.err;
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }

    fn merge_walk_results_mut(self: *const Branch, a: Allocator, left: WalkerMut, right: WalkerMut) WalkerMut {
        return WalkerMut{
            .err = if (left.err) |_| left.err else right.err,
            .keep_walking = left.keep_walking and right.keep_walking,
            .found = left.found or right.found,
            .replace = if (left.replace == null and right.replace == null)
                null
            else
                self._merge_replacements(a, left, right) catch |e| return WalkerMut{ .err = e },
        };
    }

    fn _merge_replacements(self: *const Branch, a: std.mem.Allocator, left: WalkerMut, right: WalkerMut) !*const Node {
        const new_left = if (left.replace) |p| p else self.left;
        const new_right = if (right.replace) |p| p else self.right;

        if (new_left.is_empty()) return new_right;
        if (new_right.is_empty()) return new_left;

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
        return Weights{
            .bols = if (self.bol) 1 else 0,
            .eols = if (self.eol) 1 else 0,
            .len = @intCast(len),
        };
    }

    inline fn is_empty(self: *const Leaf) bool {
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

fn num_of_chars(str: []const u8) usize {
    var iter = code_point.Iterator{ .bytes = str };
    var num_chars: usize = 0;
    while (iter.next()) |_| num_chars += 1;
    return num_chars;
}

fn byte_count_for_range(str: []const u8, start: usize, end: usize) usize {
    var iter = code_point.Iterator{ .bytes = str };
    var byte_count: usize = 0;
    var i: usize = 0;
    while (iter.next()) |cp| {
        if (i >= start and i < end) byte_count += cp.len;
        i += 1;
    }
    return byte_count;
}

//////////////////////////////////////////////////////////////////////////////////////////////

test "Buffer.create() & Buffer.deinit()" {
    const empty_buffer = try Buffer.create(std.testing.allocator, std.testing.allocator);
    defer empty_buffer.deinit();

    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 2 }, empty_buffer.root.weights_sum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.left.weights_sum());
    try eqDeep(Weights{ .bols = 0, .eols = 0, .len = 0, .depth = 1 }, empty_buffer.root.node.right.weights_sum());
}

fn testBufferGetLine(a: std.mem.Allocator, buf: *Buffer, line: usize, expected: []const u8) !void {
    var result = ArrayList(u8).init(a);
    defer result.deinit();
    try buf.get_line(line, &result);
    try std.testing.expectEqualStrings(expected, result.items);
}

test "Buffer.get_line()" {
    const a = std.testing.allocator;
    var buf = try Buffer.create(a, a);
    defer buf.deinit();

    {
        buf.root = try buf.load_from_string("ayaya");
        try testBufferGetLine(a, buf, 0, "ayaya");
    }

    {
        buf.root = try buf.load_from_string("hello\nworld");
        try testBufferGetLine(a, buf, 0, "hello");
        try testBufferGetLine(a, buf, 1, "world");
        try shouldErr(error.NotFound, testBufferGetLine(a, buf, 2, ""));
    }
}

test "Buffer.insert_chars()" {
    const a = std.testing.allocator;
    const buf = try Buffer.create(a, a);
    defer buf.deinit();

    {
        buf.root = try buf.load_from_string("B");
        try testBufferGetLine(a, buf, 0, "B");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .buf = "B", .bol = true, .eol = false }, leaves[0].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 0, "1");
        try testBufferGetLine(a, buf, 0, "1B");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .buf = "1", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "B", .bol = false, .eol = false }, leaves[1].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 1, "2");
        try testBufferGetLine(a, buf, 0, "12B");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(3, leaves.len);
            try eqDeep(Leaf{ .buf = "1", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "2", .bol = false, .eol = false }, leaves[1].*);
            try eqDeep(Leaf{ .buf = "B", .bol = false, .eol = false }, leaves[2].*);
        }
    }

    {
        buf.root = try buf.load_from_string("");
        try testBufferGetLine(a, buf, 0, "");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .buf = "", .bol = true, .eol = false }, leaves[0].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 0, "안녕");
        try testBufferGetLine(a, buf, 0, "안녕");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .buf = "안녕", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "", .bol = false, .eol = false }, leaves[1].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 2, "!");
        try testBufferGetLine(a, buf, 0, "안녕!");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .buf = "안녕", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[1].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 3, " Hello there!");
        try testBufferGetLine(a, buf, 0, "안녕! Hello there!");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(3, leaves.len);
            try eqDeep(Leaf{ .buf = "안녕", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[1].*);
            try eqDeep(Leaf{ .buf = " Hello there!", .bol = false, .eol = false }, leaves[2].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 15, " 👋");
        try testBufferGetLine(a, buf, 0, "안녕! Hello there 👋!");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(5, leaves.len);
            try eqDeep(Leaf{ .buf = "안녕", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[1].*);
            try eqDeep(Leaf{ .buf = " Hello there", .bol = false, .eol = false }, leaves[2].*);
            try eqDeep(Leaf{ .buf = " 👋", .bol = false, .eol = false }, leaves[3].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[4].*);
        }

        _, _, buf.root = try buf.insert_chars(buf.a, 0, 2, "하세요");
        try testBufferGetLine(a, buf, 0, "안녕하세요! Hello there 👋!");

        {
            const leaves = try walkThroughNodeToGetLeaves(buf.a, buf.root);
            try eq(6, leaves.len);
            try eqDeep(Leaf{ .buf = "안녕", .bol = true, .eol = false }, leaves[0].*);
            try eqDeep(Leaf{ .buf = "하세요", .bol = false, .eol = false }, leaves[1].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[2].*);
            try eqDeep(Leaf{ .buf = " Hello there", .bol = false, .eol = false }, leaves[3].*);
            try eqDeep(Leaf{ .buf = " 👋", .bol = false, .eol = false }, leaves[4].*);
            try eqDeep(Leaf{ .buf = "!", .bol = false, .eol = false }, leaves[5].*);
        }
    }
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

fn testNodeStore(a: std.mem.Allocator, buffer: *Buffer, expected: []const u8) !void {
    const root = try buffer.load_from_string(expected);
    var s = try ArrayList(u8).initCapacity(a, root.weights_sum().len);
    defer s.deinit();
    try root.store(s.writer());
    try eqStr(expected, s.items);
}

test "Node.store()" {
    const a = std.testing.allocator;
    const buffer = try Buffer.create(a, a);
    defer buffer.deinit();

    {
        try testNodeStore(a, buffer, "hello\nworld");
        try testNodeStore(a, buffer, "one two");
        try testNodeStore(a, buffer, &[_]u8{ 'A', 'A', 'A', 10 } ** 1_000);
    }
}

fn walkThroughNodeToGetLeaves(a: Allocator, node: Root) ![]*const Leaf {
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
        const root = try buffer.load_from_string("hello\nfrom\nthe\nother\nside");
        const leaves = try walkThroughNodeToGetLeaves(a, root);
        defer a.free(leaves);

        try eqDeep(Leaf{ .buf = "hello", .bol = true, .eol = true }, leaves[0].*);
        try eqDeep(Leaf{ .buf = "from", .bol = true, .eol = true }, leaves[1].*);
        try eqDeep(Leaf{ .buf = "the", .bol = true, .eol = true }, leaves[2].*);
        try eqDeep(Leaf{ .buf = "other", .bol = true, .eol = true }, leaves[3].*);
        try eqDeep(Leaf{ .buf = "side", .bol = true, .eol = false }, leaves[4].*);
    }
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

test "Leaf.is_empty()" {
    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = false };
        try eq(true, leaf.is_empty());
    }

    {
        const leaf = Leaf{ .buf = "hi!", .bol = false, .eol = false };
        try eq(false, leaf.is_empty());
    }

    {
        const leaf = Leaf{ .buf = "", .bol = true, .eol = false };
        try eq(false, leaf.is_empty());
    }

    {
        const leaf = Leaf{ .buf = "", .bol = false, .eol = true };
        try eq(false, leaf.is_empty());
    }
}

test num_of_chars {
    try eq(5, num_of_chars("hello"));
    try eq(7, num_of_chars("hello 👋"));
    try eq(2, num_of_chars("안녕"));
}

test byte_count_for_range {
    const str = "안녕! hello there 👋!";
    {
        const result = byte_count_for_range(str, 0, 2);
        try eq(6, result);
        try eqStr("안녕", str[0..result]);
    }
    {
        const result = byte_count_for_range(str, 0, 3);
        try eq(7, result);
        try eqStr("안녕!", str[0..result]);
    }
    {
        const result = byte_count_for_range(str, 4, str.len);
        try eq(17, result);
        try eqStr("hello there 👋!", str[str.len - result ..]);
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
