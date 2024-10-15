// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

// This file was modified from:
// repository: https://github.com/neurocyte/flow
// commit:     9080fd4826a08797dc58c625c045a42f2f59afc6
// file(s):    src/buffer/Buffer.zig

// MIT License
//
// Copyright (c) 2024 CJ van den Berg
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//////////////////////////////////////////////////////////////////////////////////////////////

const std = @import("std");
const rc = @import("zigrc");
const code_point = @import("code_point");

const TrimmedRc = @import("CustomRc.zig").TrimmedRc;

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

// const RcNode = rc.Rc(Node);
const RcNode = TrimmedRc(Node, u16);

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

    fn releaseChildrenRecursive(self: *const Node, a: Allocator) void {
        if (self.* == .leaf) return;
        if (self.branch.left.strongCount() == 1) self.branch.left.value.releaseChildrenRecursive(a);
        self.branch.left.release(a);
        if (self.branch.right.strongCount() == 1) self.branch.right.value.releaseChildrenRecursive(a);
        self.branch.right.release(a);
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
                root.value.releaseChildrenRecursive(testing_allocator);
                root.release(testing_allocator);
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
                old_root.value.releaseChildrenRecursive(testing_allocator);
                old_root.release(testing_allocator);
            }
            try eqStr(
                \\2 2/11
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, old_root));

            {
                const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
                defer {
                    new_root.value.releaseChildrenRecursive(testing_allocator);
                    new_root.release(testing_allocator);
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
                old_root.value.releaseChildrenRecursive(testing_allocator);
                old_root.release(testing_allocator);
                try eqStr(
                    \\3 2/14
                    \\  2 1/9
                    \\    1 B| `ok `
                    \\    1 `hello` |E
                    \\  1 B| `world`
                , try debugStr(idc_if_it_leaks, new_root));
            }

            // freeing new_root later
            new_root.value.releaseChildrenRecursive(testing_allocator);
            new_root.release(testing_allocator);
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
                iterations.items[i].value.releaseChildrenRecursive(testing_allocator);
                iterations.items[i].release(testing_allocator);
            }
        }

        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            var iterations = try insertCharOneAfterAnother(testing_allocator, &content_arena, str);
            defer iterations.deinit();

            for (0..iterations.items.len) |i_| {
                const i = iterations.items.len - 1 - i_;
                iterations.items[i].value.releaseChildrenRecursive(testing_allocator);
                iterations.items[i].release(testing_allocator);
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

    const MAX_IMBALANCE = 1;

    fn calculateBalanceFactor(left: *const Node, right: *const Node) i64 {
        var balance_factor: i64 = @intCast(left.weights().depth);
        balance_factor -= right.weights().depth;
        return balance_factor;
    }

    fn balance(a: Allocator, self: RcNode) !RcNode {
        switch (self.value.*) {
            .leaf => return self,
            .branch => |branch| {
                {
                    const initial_balance_factor = calculateBalanceFactor(branch.left.value, branch.right.value);
                    if (@abs(initial_balance_factor) < MAX_IMBALANCE) return self;
                }

                var result: RcNode = undefined;
                defer if (result.value != self.value) self.release(a);

                const left = try balance(a, branch.left);
                const right = try balance(a, branch.right);
                const balance_factor = calculateBalanceFactor(left.value, right.value);

                if (@abs(balance_factor) > MAX_IMBALANCE) {
                    if (balance_factor < 0) {
                        assert(right.value.* == .branch);
                        const right_balance_factor = calculateBalanceFactor(right.value.branch.left.value, right.value.branch.right.value);
                        if (right_balance_factor <= 0) {
                            const this = if (branch.left.value != left.value or branch.right.value != right.value) try Node.new(a, left, right) else self;
                            result = try rotateLeft(a, this);
                        } else {
                            const new_right = try rotateRight(a, right);
                            const this = try Node.new(a, left, new_right);
                            result = try rotateLeft(a, this);
                        }
                    } else {
                        assert(left.value.* == .branch);
                        const left_balance_factor = calculateBalanceFactor(left.value.branch.left.value, left.value.branch.right.value);
                        if (left_balance_factor >= 0) {
                            const this = if (branch.left.value != left.value or branch.right.value != right.value) try Node.new(a, left, right) else self;
                            result = try rotateRight(a, this);
                        } else {
                            const new_left = try rotateLeft(a, left);
                            const this = try Node.new(a, new_left, right);
                            result = try rotateRight(a, this);
                        }
                    }
                } else {
                    result = if (branch.left.value != left.value or branch.right.value != right.value) try Node.new(a, left, right) else self;
                }

                const should_balance_again = result.value.* == .branch and @abs(calculateBalanceFactor(result.value.branch.left.value, result.value.branch.right.value)) > MAX_IMBALANCE;
                if (should_balance_again) result = try balance(a, result);

                return result;
            },
        }
    }

    test balance {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        var node_list = try insertCharOneAfterAnother(testing_allocator, &content_arena, "abcde");
        defer node_list.deinit();

        // check if balancing a 'before node' doesn't mess up 'after node' (no segfault)
        // in this case, 'before node' is `len-2`, 'after node' is `len-1`
        {
            const minus_i = 2;
            const original_dbg_str =
                \\4 1/4
                \\  1 B| `a` Rc:4
                \\  3 0/3
                \\    1 `b` Rc:3
                \\    2 0/2
                \\      1 `c` Rc:2
                \\      1 `d`
            ;
            try eqStr(original_dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - minus_i]));

            const balanced = try balance(testing_allocator, node_list.items[node_list.items.len - minus_i]);
            node_list.items[node_list.items.len - minus_i] = balanced;
            const balanced_dbg_str =
                \\3 1/4
                \\  2 1/2
                \\    1 B| `a` Rc:4
                \\    1 `b` Rc:3
                \\  2 0/2
                \\    1 `c` Rc:2
                \\    1 `d`
            ;
            try eqStr(balanced_dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - minus_i]));
        }
        {
            const minus_i = 1;
            const original_dbg_str =
                \\5 1/5
                \\  1 B| `a` Rc:4
                \\  4 0/4
                \\    1 `b` Rc:3
                \\    3 0/3
                \\      1 `c` Rc:2
                \\      2 0/2
                \\        1 `d`
                \\        1 `e`
            ;
            try eqStr(original_dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - minus_i]));

            const balanced = try balance(testing_allocator, node_list.items[node_list.items.len - minus_i]);
            node_list.items[node_list.items.len - minus_i] = balanced;
            const balanced_dbg_str =
                \\4 1/5
                \\  3 1/3
                \\    1 B| `a` Rc:4
                \\    2 0/2
                \\      1 `b` Rc:3
                \\      1 `c` Rc:2
                \\  2 0/2
                \\    1 `d`
                \\    1 `e`
            ;
            try eqStr(balanced_dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - minus_i]));
        }

        // check if previous steps are still accessible (no segfault)
        {
            const dbg_str =
                \\2 1/1
                \\  1 B| `a`
                \\  1 ``
            ;
            try eqStr(dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - 5]));
        }
        {
            const dbg_str =
                \\2 1/2
                \\  1 B| `a` Rc:4
                \\  1 `b`
            ;
            try eqStr(dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - 4]));
        }
        {
            const dbg_str =
                \\3 1/3
                \\  1 B| `a` Rc:4
                \\  2 0/2
                \\    1 `b` Rc:3
                \\    1 `c`
            ;
            try eqStr(dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - 3]));
        }
        {
            const dbg_str =
                \\3 1/4
                \\  2 1/2
                \\    1 B| `a` Rc:4
                \\    1 `b` Rc:3
                \\  2 0/2
                \\    1 `c` Rc:2
                \\    1 `d`
            ;
            try eqStr(dbg_str, try debugStr(idc_if_it_leaks, node_list.items[node_list.items.len - 2]));
        }

        freeRcNodes(node_list.items);
    }

    fn rotateLeft(allocator: Allocator, self: RcNode) !RcNode {
        assert(self.value.* == .branch);
        defer self.release(allocator);

        const other = self.value.branch.right;
        defer other.release(allocator);
        assert(other.value.* == .branch);

        const a = try Node.new(allocator, self.value.branch.left, other.value.branch.left);
        const b = try Node.new(allocator, a, other.value.branch.right);
        return b;
    }

    test rotateLeft {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
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

        // IMPORTANT: the `abcde` before roation is no longer available, accessing it will cause segfault

        freeRcNodes(&.{ acd, abcd, abcde_rotated });
    }

    fn rotateRight(allocator: Allocator, self: RcNode) !RcNode {
        assert(self.value.* == .branch);
        defer self.release(allocator);

        const other = self.value.branch.left;
        defer other.release(allocator);
        assert(other.value.* == .branch);

        const a = try Node.new(allocator, self.value.branch.right, other.value.branch.right);
        const b = try Node.new(allocator, other.value.branch.left, a);
        return b;
    }

    test rotateRight {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        const abc = try Node.fromString(testing_allocator, &content_arena, "ABC");
        _, _, const abcd = try insertChars(abc, testing_allocator, &content_arena, "D", .{ .line = 0, .col = 3 });
        _, _, const _abcd = try insertChars(abcd, testing_allocator, &content_arena, "_", .{ .line = 0, .col = 0 });
        const _abcd_dbg =
            \\3 1/5
            \\  2 1/4
            \\    1 B| `_`
            \\    1 `ABC`
            \\  1 `D` Rc:2
        ;
        try eqStr(_abcd_dbg, try debugStr(idc_if_it_leaks, _abcd));

        const _abcd_rotated = try rotateRight(testing_allocator, _abcd);
        const _abcd_rotated_dbg =
            \\3 1/5
            \\  1 B| `_`
            \\  2 0/4
            \\    1 `D` Rc:2
            \\    1 `ABC`
        ;
        try eqStr(_abcd_rotated_dbg, try debugStr(idc_if_it_leaks, _abcd_rotated));

        // IMPORTANT: the `_abcd` before roation is no longer available, accessing it will cause segfault

        freeRcNodes(&.{ abc, abcd, _abcd_rotated });
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
        defer leaf.release(testing_allocator);

        try eq(1, leaf.strongCount());
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
    node.value.releaseChildrenRecursive(testing_allocator);
    node.release(testing_allocator);
}
