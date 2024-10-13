const std = @import("std");
const rc = @import("zigrc");
const code_point = @import("code_point");

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

const WalkMutError = error{OutOfMemory};
const WalkMutCallback = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkMutError!WalkMutResult;

pub const WalkMutResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    replace: ?RcNode = null,
    err: ?WalkMutError = null,

    pub const keep_walking = WalkMutResult{ .keep_walking = true };
    pub const stop = WalkMutResult{ .keep_walking = false };
    pub const found = WalkMutResult{ .found = true };

    pub fn merge(branch: *const Branch, a: Allocator, left: WalkMutResult, right: WalkMutResult) WalkMutError!WalkMutResult {
        var result = WalkMutResult{};
        result.err = if (left.err) |_| left.err else right.err;
        if (left.replace != null or right.replace != null) {
            var new_left: RcNode = undefined;
            if (left.replace) |replacement| new_left = replacement else {
                var branch_left_clone = branch.left;
                new_left = branch_left_clone.retain();
            }

            var new_right: RcNode = undefined;
            if (right.replace) |replacement| new_right = replacement else {
                var branch_right_clone = branch.right;
                new_right = branch_right_clone.retain();
            }

            result.replace = if (new_left.value.isEmpty())
                new_right
            else if (new_right.value.isEmpty())
                new_left
            else
                try Node.new(a, new_left, new_right);
        }
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }
};

fn walkMutFromLineBegin(a: Allocator, node: RcNode, line: usize, f: WalkMutCallback, ctx: *anyopaque) WalkMutError!WalkMutResult {
    switch (node.value.*) {
        .branch => |*branch| {
            const left_bols = node.value.weights().bols;
            if (line >= left_bols) {
                const right_result = try walkMutFromLineBegin(a, branch.right, line - left_bols, f, ctx);
                if (right_result.replace) |replacement| {
                    var result = WalkMutResult{};
                    result.err = right_result.err;
                    result.found = right_result.found;
                    result.keep_walking = right_result.keep_walking;
                    result.replace = if (replacement.value.isEmpty())
                        branch.left
                    else
                        try Node.new(a, branch.left.retain(), right_result.replace.?);
                    return result;
                }
                return right_result;
            }
            const left_result = try walkMutFromLineBegin(a, branch.left, line, f, ctx);
            const right_result = if (left_result.found and left_result.keep_walking) try walkMutFromLineBegin(a, branch.right, line, f, ctx) else WalkMutResult{};
            return WalkMutResult.merge(branch, a, left_result, right_result);
        },
        .leaf => |*leaf| {
            if (line == 0) {
                var result = try f(ctx, leaf);
                if (result.err) |_| {
                    result.replace = null;
                    return result;
                }
                result.found = true;
                return result;
            }
            return WalkMutResult.keep_walking;
        },
    }
}

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

    fn isEmpty(self: *const Node) bool {
        return switch (self.*) {
            .branch => |*branch| branch.left.value.isEmpty() and branch.right.value.isEmpty(),
            .leaf => |*leaf| leaf.isEmpty(),
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
            , try debugStr(idc_if_it_leaks, root));
        }
    }

    fn fromReader(a: Allocator, content_arena: *ArenaAllocator, reader: anytype, buffer_size: usize, first_bol: bool) !RcNode {
        const buf = try content_arena.allocator().alloc(u8, buffer_size);

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

    ///////////////////////////// Insert

    const CursorPoint = struct { line: usize, col: usize };

    const InsertCharsCtx = struct {
        a: Allocator,
        col: usize,
        abs_col: usize = 0,
        chars: []const u8,
        eol: bool,

        fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkMutError!WalkMutResult {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            const leaf_noc = getNumOfChars(leaf.buf);
            const base_col = ctx.abs_col;
            ctx.abs_col += leaf_noc;

            if (ctx.col == 0) {
                const left = try Leaf.new(ctx.a, ctx.chars, leaf.bol, ctx.eol);
                const right = try Leaf.new(ctx.a, leaf.buf, ctx.eol, leaf.eol);
                return WalkMutResult{ .replace = try Node.new(ctx.a, left, right) };
            }

            if (leaf_noc == ctx.col) {
                if (leaf.eol and ctx.eol and ctx.chars.len == 0) {
                    const left = try Leaf.new(ctx.a, leaf.buf, leaf.bol, true);
                    const right = try Leaf.new(ctx.a, ctx.chars, true, true);
                    return WalkMutResult{ .replace = try Node.new(ctx.a, left, right) };
                }

                const left = try Leaf.new(ctx.a, leaf.buf, leaf.bol, false);

                if (ctx.eol) {
                    const middle = try Leaf.new(ctx.a, ctx.chars, false, ctx.eol);
                    const right = try Leaf.new(ctx.a, "", ctx.eol, leaf.eol);
                    const mid_right = try Node.new(ctx.a, middle, right);
                    return WalkMutResult{ .replace = try Node.new(ctx.a, left, mid_right) };
                }

                const right = try Leaf.new(ctx.a, ctx.chars, false, leaf.eol);
                return WalkMutResult{ .replace = try Node.new(ctx.a, left, right) };
            }

            if (leaf_noc > ctx.col) {
                const pos = getNumOfBytesTillCol(leaf.buf, base_col);
                if (ctx.eol and ctx.chars.len == 0) {
                    const left = try Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, ctx.eol);
                    const right = try Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol);
                    return WalkMutResult{ .replace = try Node.new(ctx.a, left, right) };
                }

                const left = try Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, false);
                const middle = try Leaf.new(ctx.a, ctx.chars, false, ctx.eol);
                const right = try Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol);
                const mid_right = try Node.new(ctx.a, middle, right);
                return WalkMutResult{ .replace = try Node.new(ctx.a, left, mid_right) };
            }

            ctx.col -= leaf_noc;
            return if (leaf.eol) WalkMutResult.stop else WalkMutResult.keep_walking;
        }
    };

    const InsertCharsError = error{ OutOfMemory, InputLenZero, ColumnOutOfBounds };
    fn insertChars(self_: RcNode, a: Allocator, content_arena: *ArenaAllocator, chars: []const u8, destination: CursorPoint) InsertCharsError!struct { usize, usize, RcNode } {
        if (chars.len == 0) return error.InputLenZero;
        var self = self_;

        var rest = try content_arena.allocator().dupe(u8, chars);
        var chunk = rest;
        var line = destination.line;
        var col = destination.col;
        var need_eol = false;

        while (rest.len > 0) {
            chunk_blk: {
                if (std.mem.indexOfScalar(u8, rest, '\n')) |eol| {
                    chunk = rest[0..eol];
                    rest = rest[eol + 1 ..];
                    need_eol = true;
                    break :chunk_blk;
                }

                chunk = rest;
                rest = &[_]u8{};
                need_eol = false;
            }

            var ctx: InsertCharsCtx = .{ .a = a, .col = destination.col, .chars = chunk, .eol = need_eol };
            const result = try walkMutFromLineBegin(a, self, destination.line, InsertCharsCtx.walker, &ctx);

            if (!result.found) return error.ColumnOutOfBounds;
            if (result.replace) |root| self = root;

            eol_blk: {
                if (need_eol) {
                    line += 1;
                    col = 0;
                    break :eol_blk;
                }
                col += getNumOfChars(chunk);
            }
        }

        return .{ line, col, self };
    }

    test insertChars {
        // freeing last history first
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            const old_root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld", true);
            defer {
                old_root.value.releaseChildrenRecursive();
                old_root.release();
                content_arena.deinit();
            }
            try eqStr(
                \\2 2/11
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, old_root));

            {
                const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
                defer {
                    new_root.value.releaseChildrenRecursive();
                    new_root.release();
                }

                try eqStr(
                    \\2 2/11
                    \\  1 B| `hello` |E
                    \\  1 B| `world` Rc:2
                , try debugStr(idc_if_it_leaks, old_root));

                try eq(.{ 0, 3 }, .{ line, col });
                try eqStr(
                    \\3 2/14
                    \\  2 1/9
                    \\    1 B| `ok `
                    \\    1 `hello` |E
                    \\  1 B| `world` Rc:2
                , try debugStr(idc_if_it_leaks, new_root));
            }
        }

        // freeing first history first
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();

            // before
            const old_root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld", true);
            try eqStr(
                \\2 2/11
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, old_root));

            // after insertChars()
            const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
            {
                try eqStr(
                    \\2 2/11
                    \\  1 B| `hello` |E
                    \\  1 B| `world` Rc:2
                , try debugStr(idc_if_it_leaks, old_root));

                try eq(.{ 0, 3 }, .{ line, col });
                try eqStr(
                    \\3 2/14
                    \\  2 1/9
                    \\    1 B| `ok `
                    \\    1 `hello` |E
                    \\  1 B| `world` Rc:2
                , try debugStr(idc_if_it_leaks, new_root));
            }

            // freeing old_root first
            {
                old_root.value.releaseChildrenRecursive();
                old_root.release();
                try eqStr(
                    \\3 2/14
                    \\  2 1/9
                    \\    1 B| `ok `
                    \\    1 `hello` |E
                    \\  1 B| `world`
                , try debugStr(idc_if_it_leaks, new_root));
            }

            // freeing new_root later
            new_root.value.releaseChildrenRecursive();
            new_root.release();
        }
    }

    ///////////////////////////// Debug Print

    fn debugStr(a: Allocator, node: RcNode) ![]const u8 {
        var result = std.ArrayList(u8).init(a);
        try _buildDebugStr(a, node, &result, 0);
        return try result.toOwnedSlice();
    }

    fn _buildDebugStr(a: Allocator, node: RcNode, result: *std.ArrayList(u8), indent_level: usize) !void {
        if (indent_level > 0) try result.append('\n');
        for (0..indent_level) |_| try result.append(' ');
        switch (node.value.*) {
            .branch => |branch| {
                const strong_count = if (node.strongCount() == 1) "" else try std.fmt.allocPrint(a, " Rc:{d}", .{node.strongCount()});
                const content = try std.fmt.allocPrint(a, "{d} {d}/{d}{s}", .{ branch.weights.depth, branch.weights.bols, branch.weights.len, strong_count });
                defer a.free(content);
                try result.appendSlice(content);
                try _buildDebugStr(a, branch.left, result, indent_level + 2);
                try _buildDebugStr(a, branch.right, result, indent_level + 2);
            },
            .leaf => |leaf| {
                const bol = if (leaf.bol) "B| " else "";
                const eol = if (leaf.eol) " |E" else "";
                const strong_count = if (node.strongCount() == 1) "" else try std.fmt.allocPrint(a, " Rc:{d}", .{node.strongCount()});
                const leaf_content = if (leaf.buf.len > 0) leaf.buf else "";
                const content = try std.fmt.allocPrint(a, "1 {s}`{s}`{s}{s}", .{ bol, leaf_content, eol, strong_count });
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

    fn isEmpty(self: *const Leaf) bool {
        return self.buf.len == 0 and !self.bol and !self.eol;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

fn getNumOfBytesTillCol(str: []const u8, col: usize) usize {
    var iter = code_point.Iterator{ .bytes = str };
    var num_of_bytes: usize = 0;
    var num_chars: u32 = 0;
    while (iter.next()) |cp| {
        defer num_chars += 1;
        if (num_chars == col) break;
        num_of_bytes += cp.len;
    }
    return num_chars;
}

fn getNumOfChars(str: []const u8) u32 {
    var iter = code_point.Iterator{ .bytes = str };
    var num_chars: u32 = 0;
    while (iter.next()) |_| num_chars += 1;
    return num_chars;
}

test getNumOfChars {
    try eq(5, getNumOfChars("hello"));
    try eq(7, getNumOfChars("hello 👋"));
    try eq(2, getNumOfChars("안녕"));
}

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    std.testing.refAllDecls(Node);
    std.testing.refAllDecls(Leaf);
}
