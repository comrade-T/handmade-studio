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

    pub const keep_walking = WalkMutResult{ .keep_walking = true };
    pub const stop = WalkMutResult{ .keep_walking = false };
    pub const found = WalkMutResult{ .found = true };

    pub fn merge(branch: *const Branch, a: Allocator, left: WalkMutResult, right: WalkMutResult) WalkMutError!WalkMutResult {
        var result = WalkMutResult{};

        if (left.replace != null or right.replace != null) {
            var new_left: RcNode = undefined;
            pick_left: {
                if (left.replace) |r| {
                    new_left = r;
                    break :pick_left;
                }
                if (branch.left.value.isEmpty()) {
                    new_left = branch.left;
                    break :pick_left;
                }
                var clone = branch.left;
                new_left = clone.retain();
            }

            var new_right: RcNode = undefined;
            pick_right: {
                if (right.replace) |r| {
                    new_right = r;
                    break :pick_right;
                }
                if (branch.right.value.isEmpty()) {
                    new_right = branch.right;
                    break :pick_right;
                }
                var clone = branch.right;
                new_right = clone.retain();
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
            const left_bols = branch.left.value.weights().bols;
            if (line >= left_bols) {
                const right = try walkMutFromLineBegin(a, branch.right, line - left_bols, f, ctx);
                if (right.replace) |replacement| {
                    var result = WalkMutResult{};
                    result.found = right.found;
                    result.keep_walking = right.keep_walking;
                    result.replace = if (replacement.value.isEmpty())
                        branch.left.retain()
                    else
                        try Node.new(a, branch.left.retain(), right.replace.?);
                    return result;
                }
                return right;
            }
            const left = try walkMutFromLineBegin(a, branch.left, line, f, ctx);
            const right = if (left.found and left.keep_walking) try walkMut(a, branch.right, f, ctx) else WalkMutResult{};

            return WalkMutResult.merge(branch, a, left, right);
        },
        .leaf => |*leaf| {
            if (line == 0) {
                var result = try f(ctx, leaf);
                result.found = true;
                return result;
            }
            return WalkMutResult.keep_walking;
        },
    }
}

fn walkMut(a: Allocator, node: RcNode, f: WalkMutCallback, ctx: *anyopaque) WalkMutError!WalkMutResult {
    switch (node.value.*) {
        .branch => |*branch| {
            const left = try walkMut(a, branch.left, f, ctx);
            if (!left.keep_walking) {
                var result = WalkMutResult{};
                result.found = left.found;
                if (left.replace) |r| result.replace = try Node.new(a, r, branch.right.retain());
                return result;
            }
            const right_result = try walkMut(a, branch.right, f, ctx);
            return WalkMutResult.merge(branch, a, left, right_result);
        },
        .leaf => |*leaf| return f(ctx, leaf),
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
        if (self.branch.left.strongCount() == 1) self.branch.left.value.releaseChildrenRecursive();
        self.branch.left.release();
        if (self.branch.right.strongCount() == 1) self.branch.right.value.releaseChildrenRecursive();
        self.branch.right.release();
    }

    ///////////////////////////// Load

    fn fromString(a: Allocator, arena: *ArenaAllocator, source: []const u8) !RcNode {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, arena, stream.reader(), source.len);
    }

    test fromString {
        // without bol
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            const root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld");
            defer {
                root.value.releaseChildrenRecursive();
                root.release();
            }
            try eqStr(
                \\2 2/11
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, root));
        }
    }

    fn fromReader(a: Allocator, content_arena: *ArenaAllocator, reader: anytype, buffer_size: usize) !RcNode {
        const buf = try content_arena.allocator().alloc(u8, buffer_size);

        const read_size = try reader.read(buf);
        if (read_size != buffer_size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) return error.Unexpected;

        const leaves = try createLeavesByNewLine(a, buf);
        defer a.free(leaves);
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

        if (leaves.len != cur_leaf + 1) return error.Unexpected;
        return leaves;
    }

    test createLeavesByNewLine {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "" }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "\n");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "" }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "hello\nworld");
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "hello" }, leaves[0].value.leaf);
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
        chars: []const u8,
        eol: bool,

        fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkMutError!WalkMutResult {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            const leaf_noc = getNumOfChars(leaf.buf);

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
                const pos = getNumOfBytesTillCol(leaf.buf, ctx.col);
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

    test "insertChars - single insertion at beginning" {
        // freeing last history first
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();

            const old_root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld");
            defer {
                old_root.value.releaseChildrenRecursive();
                old_root.release();
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
            const old_root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld");
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

    test "insertChars - insert in middle of leaf" {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        const original = try Node.fromString(testing_allocator, &content_arena, "hello");

        // `hello` -> `he3llo`
        const l1, const c1, const e1 = try insertChars(original, testing_allocator, &content_arena, "3", .{ .line = 0, .col = 2 });
        try eq(.{ 0, 3 }, .{ l1, c1 });
        try eqStr(
            \\3 1/6
            \\  1 B| `he`
            \\  2 0/4
            \\    1 `3`
            \\    1 `llo`
        , try debugStr(idc_if_it_leaks, e1));

        // `he3llo` -> `he3ll0o`
        const l2, const c2, const e2 = try insertChars(e1, testing_allocator, &content_arena, "0", .{ .line = 0, .col = 5 });
        try eq(.{ 0, 6 }, .{ l2, c2 });
        try eqStr(
            \\5 1/7
            \\  1 B| `he` Rc:2
            \\  4 0/5
            \\    1 `3` Rc:2
            \\    3 0/4
            \\      1 `ll`
            \\      2 0/2
            \\        1 `0`
            \\        1 `o`
        , try debugStr(idc_if_it_leaks, e2));

        // `he3ll0o` -> `he3ll\n0o`
        const l3, const c3, const e3 = try insertChars(e2, testing_allocator, &content_arena, "\n", .{ .line = 0, .col = 5 });
        try eq(.{ 1, 0 }, .{ l3, c3 });
        try eqStr(
            \\6 2/8
            \\  1 B| `he` Rc:3
            \\  5 1/6
            \\    1 `3` Rc:3
            \\    4 1/5
            \\      3 1/3
            \\        1 `ll`
            \\        2 1/1
            \\          1 `` |E
            \\          1 B| ``
            \\      2 0/2 Rc:2
            \\        1 `0`
            \\        1 `o`
        , try debugStr(idc_if_it_leaks, e3));

        freeRcNodes(&.{ original, e1, e2, e3 });
    }

    test "insertChars - multiple insertions from empty string" {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        const a = testing_allocator;

        // original
        const r0 = try Node.fromString(a, &content_arena, "");
        try eqStr(
            \\1 B| ``
        , try debugStr(idc_if_it_leaks, r0));

        // 1st edit
        const l1, const c1, const r1 = try insertChars(r0, a, &content_arena, "h", .{ .line = 0, .col = 0 });
        {
            try eqStr(
                \\1 B| ``
            , try debugStr(idc_if_it_leaks, r0));

            try eq(.{ 0, 1 }, .{ l1, c1 });
            try eqStr(
                \\2 1/1
                \\  1 B| `h`
                \\  1 ``
            , try debugStr(idc_if_it_leaks, r1));
        }

        // 2st edit
        const l2, const c2, const r2 = try insertChars(r1, a, &content_arena, "e", .{ .line = l1, .col = c1 });
        {
            try eqStr(
                \\1 B| ``
            , try debugStr(idc_if_it_leaks, r0));

            try eqStr(
                \\2 1/1
                \\  1 B| `h`
                \\  1 ``
            , try debugStr(idc_if_it_leaks, r1));

            try eq(.{ 0, 2 }, .{ l2, c2 });
            try eqStr(
                \\2 1/2
                \\  1 B| `h`
                \\  1 `e`
            , try debugStr(idc_if_it_leaks, r2));
        }

        const l3, const c3, const r3 = try insertChars(r2, a, &content_arena, "l", .{ .line = l2, .col = c2 });
        // 3rd edit
        {
            try eqStr(
                \\1 B| ``
            , try debugStr(idc_if_it_leaks, r0));

            try eqStr(
                \\2 1/1
                \\  1 B| `h`
                \\  1 ``
            , try debugStr(idc_if_it_leaks, r1));

            try eqStr(
                \\2 1/2
                \\  1 B| `h` Rc:2
                \\  1 `e`
            , try debugStr(idc_if_it_leaks, r2));

            try eq(.{ 0, 3 }, .{ l3, c3 });
            try eqStr(
                \\3 1/3
                \\  1 B| `h` Rc:2
                \\  2 0/2
                \\    1 `e`
                \\    1 `l`
            , try debugStr(idc_if_it_leaks, r3));
        }

        const l4, const c4, const r4 = try insertChars(r3, a, &content_arena, "3", .{ .line = 0, .col = 1 });
        // 4rd edit
        {
            try eqStr(
                \\1 B| ``
            , try debugStr(idc_if_it_leaks, r0));

            try eqStr(
                \\2 1/1
                \\  1 B| `h`
                \\  1 ``
            , try debugStr(idc_if_it_leaks, r1));

            try eqStr(
                \\2 1/2
                \\  1 B| `h` Rc:2
                \\  1 `e`
            , try debugStr(idc_if_it_leaks, r2));

            try eqStr(
                \\3 1/3
                \\  1 B| `h` Rc:2
                \\  2 0/2 Rc:2
                \\    1 `e`
                \\    1 `l`
            , try debugStr(idc_if_it_leaks, r3));

            try eq(.{ 0, 2 }, .{ l4, c4 });
            try eqStr(
                \\3 1/4
                \\  2 1/2
                \\    1 B| `h`
                \\    1 `3`
                \\  2 0/2 Rc:2
                \\    1 `e`
                \\    1 `l`
            , try debugStr(idc_if_it_leaks, r4));
        }

        const l5, const c5, const r5 = try insertChars(r4, a, &content_arena, "// ", .{ .line = 0, .col = 0 });
        {
            try eq(.{ 0, 3 }, .{ l5, c5 });
            try eqStr(
                \\4 1/7
                \\  3 1/5
                \\    2 1/4
                \\      1 B| `// `
                \\      1 `h`
                \\    1 `3` Rc:2
                \\  2 0/2 Rc:3
                \\    1 `e`
                \\    1 `l`
            , try debugStr(idc_if_it_leaks, r5));
        }

        const l6a, const c6a, const r6a = try insertChars(r5, a, &content_arena, "o", .{ .line = 0, .col = 7 });
        {
            try eq(.{ 0, 8 }, .{ l6a, c6a });
            try eqStr( // h3elo
                \\4 1/8
                \\  3 1/5 Rc:2
                \\    2 1/4
                \\      1 B| `// `
                \\      1 `h`
                \\    1 `3` Rc:2
                \\  3 0/3
                \\    1 `e` Rc:2
                \\    2 0/2
                \\      1 `l`
                \\      1 `o`
            , try debugStr(idc_if_it_leaks, r6a));
        }

        const l6b, const c6b, const r6b = try insertChars(r5, a, &content_arena, "x", .{ .line = 0, .col = 6 });
        {
            try eq(.{ 0, 7 }, .{ l6b, c6b });
            try eqStr( // h3exl
                \\4 1/8
                \\  3 1/5 Rc:3
                \\    2 1/4
                \\      1 B| `// `
                \\      1 `h`
                \\    1 `3` Rc:2
                \\  3 0/3
                \\    2 0/2
                \\      1 `e`
                \\      1 `x`
                \\    1 `l` Rc:2
            , try debugStr(idc_if_it_leaks, r6b));
        }

        const l6c, const c6c, const r6c = try insertChars(r5, a, &content_arena, "x", .{ .line = 0, .col = 5 });
        {
            try eq(.{ 0, 6 }, .{ l6c, c6c });
            try eqStr( // h3xel
                \\4 1/8
                \\  3 1/6
                \\    2 1/4 Rc:2
                \\      1 B| `// `
                \\      1 `h`
                \\    2 0/2
                \\      1 `3`
                \\      1 `x`
                \\  2 0/2 Rc:4
                \\    1 `e` Rc:2
                \\    1 `l` Rc:2
            , try debugStr(idc_if_it_leaks, r6c));
        }

        freeRcNodes(&.{ r0, r1, r2, r3, r4, r5, r6a, r6b });

        try eqStr( // h3xel
            \\4 1/8
            \\  3 1/6
            \\    2 1/4
            \\      1 B| `// `
            \\      1 `h`
            \\    2 0/2
            \\      1 `3`
            \\      1 `x`
            \\  2 0/2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, r6c));

        freeRcNode(r6c);
    }

    test "insertChars - abcd" {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        const acd = try Node.fromString(testing_allocator, &content_arena, "ACD");
        defer freeRcNode(acd);

        _, _, const abcd = try insertChars(acd, testing_allocator, &content_arena, "B", .{ .line = 0, .col = 1 });
        defer freeRcNode(abcd);
        const abcd_dbg =
            \\3 1/4
            \\  1 B| `A`
            \\  2 0/3
            \\    1 `B`
            \\    1 `CD`
        ;
        try eqStr(abcd_dbg, try debugStr(idc_if_it_leaks, abcd));

        {
            _, _, const eabcd = try insertChars(abcd, testing_allocator, &content_arena, "E", .{ .line = 0, .col = 0 });
            defer freeRcNode(eabcd);
            const eabcd_dbg =
                \\3 1/5
                \\  2 1/2
                \\    1 B| `E`
                \\    1 `A`
                \\  2 0/3 Rc:2
                \\    1 `B`
                \\    1 `CD`
            ;
            try eqStr(eabcd_dbg, try debugStr(idc_if_it_leaks, eabcd));
        }

        {
            _, _, const abcde = try insertChars(abcd, testing_allocator, &content_arena, "E", .{ .line = 0, .col = 4 });
            defer freeRcNode(abcde);
            const abcde_dbg =
                \\4 1/5
                \\  1 B| `A` Rc:2
                \\  3 0/4
                \\    1 `B` Rc:2
                \\    2 0/3
                \\      1 `CD`
                \\      1 `E`
            ;
            try eqStr(abcde_dbg, try debugStr(idc_if_it_leaks, abcde));
        }
    }

    test "insertChars - with newline \n" {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        const a = testing_allocator;

        // original
        const r0 = try Node.fromString(a, &content_arena, "hello venus");
        try eqStr(
            \\1 B| `hello venus`
        , try debugStr(idc_if_it_leaks, r0));

        // 1st edit
        const l1, const c1, const r1 = try insertChars(r0, a, &content_arena, "\n", .{ .line = 0, .col = 11 });
        {
            try eqStr(
                \\1 B| `hello venus`
            , try debugStr(idc_if_it_leaks, r0));

            try eq(.{ 1, 0 }, .{ l1, c1 });
            try eqStr(
                \\3 2/12
                \\  1 B| `hello venus`
                \\  2 1/1
                \\    1 `` |E
                \\    1 B| ``
            , try debugStr(idc_if_it_leaks, r1));
        }

        // 2nd edit
        const l2, const c2, const r2 = try insertChars(r1, a, &content_arena, "h", .{ .line = 1, .col = 0 });
        {
            try eqStr(
                \\3 2/12
                \\  1 B| `hello venus` Rc:2
                \\  2 1/1
                \\    1 `` |E Rc:2
                \\    1 B| ``
            , try debugStr(idc_if_it_leaks, r1));

            try eq(.{ 1, 1 }, .{ l2, c2 });
            try eqStr(
                \\4 2/13
                \\  1 B| `hello venus` Rc:2
                \\  3 1/2
                \\    1 `` |E Rc:2
                \\    2 1/1
                \\      1 B| `h`
                \\      1 ``
            , try debugStr(idc_if_it_leaks, r2));
        }

        freeRcNodes(&.{ r0, r1, r2 });
    }

    test "insertChars - testing free order after inserting one character after another" {
        try freeBackAndForth("h");
        try freeBackAndForth("hi");
        try freeBackAndForth("hello");

        try freeBackAndForth("hello venus");
        try freeBackAndForth("hello\nvenus");

        try freeBackAndForth("hello venus and mars");
        try freeBackAndForth("hello venus\nand mars");
    }

    fn insertCharOneAfterAnother(a: Allocator, content_arena: *ArenaAllocator, str: []const u8) !ArrayList(RcNode) {
        var list = try ArrayList(RcNode).initCapacity(a, str.len + 1);
        var node = try Node.fromString(a, content_arena, "");
        try list.append(node);
        var line: usize = 0;
        var col: usize = 0;
        for (str) |char| {
            line, col, node = try insertChars(node, a, content_arena, &.{char}, .{ .line = line, .col = col });
            try list.append(node);
        }
        return list;
    }

    fn freeBackAndForth(str: []const u8) !void {
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            var iterations = try insertCharOneAfterAnother(testing_allocator, &content_arena, str);
            defer iterations.deinit();

            for (0..iterations.items.len) |i| {
                iterations.items[i].value.releaseChildrenRecursive();
                iterations.items[i].release();
            }
        }

        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            var iterations = try insertCharOneAfterAnother(testing_allocator, &content_arena, str);
            defer iterations.deinit();

            for (0..iterations.items.len) |i_| {
                const i = iterations.items.len - 1 - i_;
                iterations.items[i].value.releaseChildrenRecursive();
                iterations.items[i].release();
            }
        }
    }

    ///////////////////////////// Delete

    const DeleteCharsCtx = struct {
        a: Allocator,
        col: usize,
        count: usize,
        delete_next_bol: bool = false,

        fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkMutError!WalkMutResult {
            const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
            var result = WalkMutResult.keep_walking;

            if (ctx.delete_next_bol and ctx.count == 0) {
                result.replace = try Leaf.new(ctx.a, leaf.buf, false, leaf.eol);
                result.keep_walking = false;
                ctx.delete_next_bol = false;
                return result;
            }

            const leaf_noc = getNumOfChars(leaf.buf);
            const leaf_bol = leaf.bol and !ctx.delete_next_bol;
            ctx.delete_next_bol = false;

            // next node
            if (ctx.col > leaf_noc) {
                ctx.count -= leaf_noc;
                if (leaf.eol) ctx.col -= 1;
                return result;
            }

            // this node
            defer {
                if (ctx.count == 0 and !ctx.delete_next_bol) result.keep_walking = false;
            }

            if (ctx.col == 0) {
                if (ctx.count > leaf_noc) {
                    ctx.count -= leaf_noc;
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, false);
                    if (leaf.eol) {
                        ctx.count -= 1;
                        ctx.delete_next_bol = true;
                    }
                    return result;
                }

                if (ctx.count == leaf_noc) {
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, leaf.eol);
                    ctx.count = 0;
                    return result;
                }

                const pos = getNumOfBytesTillCol(leaf.buf, ctx.count);
                result.replace = try Leaf.new(ctx.a, leaf.buf[pos..], leaf_bol, leaf.eol);
                ctx.count = 0;
                return result;
            }

            if (ctx.col == leaf_noc) {
                if (leaf.eol) {
                    ctx.count -= 1;
                    result.replace = try Leaf.new(ctx.a, leaf.buf, leaf_bol, false);
                    ctx.delete_next_bol = true;
                }
                ctx.col -= leaf_noc;
                return result;
            }

            if (ctx.col + ctx.count >= leaf_noc) {
                ctx.count -= leaf_noc - ctx.col;
                const pos = getNumOfBytesTillCol(leaf.buf, ctx.col);
                const leaf_eol = if (leaf.eol and ctx.count > 0) leaf_eol: {
                    ctx.count -= 1;
                    ctx.delete_next_bol = true;
                    break :leaf_eol false;
                } else leaf.eol;
                result.replace = try Leaf.new(ctx.a, leaf.buf[0..pos], leaf_bol, leaf_eol);
                ctx.col = 0;
                return result;
            }

            const pos_start = getNumOfBytesTillCol(leaf.buf, ctx.col);
            const pos_end = getNumOfBytesTillCol(leaf.buf, ctx.col + ctx.count);
            const left = try Leaf.new(ctx.a, leaf.buf[0..pos_start], leaf_bol, false);
            const right = try Leaf.new(ctx.a, leaf.buf[pos_end..], false, leaf.eol);
            result.replace = try Node.new(ctx.a, left, right);
            ctx.count = 0;

            return result;
        }
    };

    fn deleteChars(self: RcNode, a: Allocator, destination: CursorPoint, count: usize) error{ OutOfMemory, Stop, NotFound }!RcNode {
        var ctx = DeleteCharsCtx{ .a = a, .col = destination.col, .count = count };
        const result = try walkMutFromLineBegin(a, self, destination.line, DeleteCharsCtx.walker, &ctx);
        if (result.found) return result.replace orelse error.Stop;
        return error.NotFound;
    }

    test "deleteChars - basics" {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        const original = try Node.fromString(testing_allocator, &content_arena, "1234567");
        defer freeRcNode(original);

        {
            const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 0 }, 1);
            defer freeRcNode(edit);
            try eqStr(
                \\1 B| `234567`
            , try debugStr(idc_if_it_leaks, edit));
        }

        {
            const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 3 }, 1);
            defer freeRcNode(edit);
            try eqStr(
                \\2 1/6
                \\  1 B| `123`
                \\  1 `567`
            , try debugStr(idc_if_it_leaks, edit));
        }

        {
            const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
            defer freeRcNode(edit);
            try eqStr(
                \\2 1/6
                \\  1 B| `12345`
                \\  1 `7`
            , try debugStr(idc_if_it_leaks, edit));
        }

        {
            const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 6 }, 1);
            defer freeRcNode(edit);
            try eqStr(
                \\1 B| `123456`
            , try debugStr(idc_if_it_leaks, edit));
        }
    }

    ///////////////////////////// Balancing

    fn rotateLeft(allocator: Allocator, self: RcNode) !RcNode {
        assert(self.value.* == .branch);
        defer self.release();

        const other = self.value.branch.right;
        defer other.release();
        assert(other.value.* == .branch);

        const a = try Node.new(allocator, self.value.branch.left, other.value.branch.left);
        const b = try Node.new(allocator, a, other.value.branch.right);
        return b;
    }

    test rotateLeft {
        var content_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer content_arena.deinit();

        const acd = try Node.fromString(testing_allocator, &content_arena, "ACD");
        _, _, const abcd = try insertChars(acd, testing_allocator, &content_arena, "B", .{ .line = 0, .col = 1 });
        _, _, const abcde = try insertChars(abcd, testing_allocator, &content_arena, "E", .{ .line = 0, .col = 4 });

        const abcde_dbg =
            \\4 1/5
            \\  1 B| `A` Rc:2
            \\  3 0/4
            \\    1 `B` Rc:2
            \\    2 0/3
            \\      1 `CD`
            \\      1 `E`
        ;
        try eqStr(abcde_dbg, try debugStr(idc_if_it_leaks, abcde));

        const abcde_rotated = try rotateLeft(testing_allocator, abcde);
        const abcde_rotated_dbg =
            \\3 1/5
            \\  2 1/2
            \\    1 B| `A` Rc:2
            \\    1 `B` Rc:2
            \\  2 0/3
            \\    1 `CD`
            \\    1 `E`
        ;
        try eqStr(abcde_rotated_dbg, try debugStr(idc_if_it_leaks, abcde_rotated));

        // IMPORTANT: the `abcde` before roation is no longer available

        freeRcNodes(&.{ acd, abcd, abcde_rotated });
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
    while (iter.next()) |cp| {
        num_of_bytes += cp.len;
        if (iter.i == col) break;
    }
    return num_of_bytes;
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

//////////////////////////////////////////////////////////////////////////////////////////////

fn freeRcNodes(nodes: []const RcNode) void {
    for (nodes) |node| freeRcNode(node);
}

fn freeRcNode(node: RcNode) void {
    node.value.releaseChildrenRecursive();
    node.release();
}
