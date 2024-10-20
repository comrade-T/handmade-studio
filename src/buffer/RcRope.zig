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

pub const EolMode = enum { lf, crlf };

//////////////////////////////////////////////////////////////////////////////////////////////

const WalkError = error{OutOfMemory};
const WalkCallback = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkError!WalkResult;

pub const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    replace: ?RcNode = null,

    pub const keep_walking = WalkResult{ .keep_walking = true };
    pub const stop = WalkResult{ .keep_walking = false };
    pub const found = WalkResult{ .found = true };

    pub fn merge(branch: *const Branch, a: Allocator, left: WalkResult, right: WalkResult) WalkError!WalkResult {
        var result = WalkResult{};

        if (left.replace != null or right.replace != null) replace: {
            var new_left: RcNode = undefined;
            var new_left_is_replace = false;
            pick_left: {
                if (left.replace) |r| {
                    new_left_is_replace = true;
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
            var new_right_is_replace = false;
            pick_right: {
                if (right.replace) |r| {
                    new_right_is_replace = true;
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

            if (new_left.value.isEmpty()) {
                result.replace = new_right;
                if (new_left_is_replace) new_left.release(testing_allocator);
                break :replace;
            }

            if (new_right.value.isEmpty()) {
                result.replace = new_left;
                if (new_right_is_replace) new_right.release(testing_allocator);
                break :replace;
            }

            result.replace = try Node.new(a, new_left, new_right);
        }

        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        return result;
    }
};

fn walkFromLineBegin(a: Allocator, node: RcNode, line: usize, f: WalkCallback, ctx: *anyopaque) WalkError!WalkResult {
    switch (node.value.*) {
        .branch => |*branch| {
            const left_bols = branch.left.value.weights().bols;
            if (line >= left_bols) {
                const right = try walkFromLineBegin(a, branch.right, line - left_bols, f, ctx);
                if (right.replace) |replacement| {
                    var result = WalkResult{};
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
            const left = try walkFromLineBegin(a, branch.left, line, f, ctx);
            const right = if (left.found and left.keep_walking) try walk(a, branch.right, f, ctx) else WalkResult{};

            return WalkResult.merge(branch, a, left, right);
        },
        .leaf => |*leaf| {
            if (line == 0) {
                var result = try f(ctx, leaf);
                result.found = true;
                return result;
            }
            return WalkResult.keep_walking;
        },
    }
}

fn walk(a: Allocator, node: RcNode, f: WalkCallback, ctx: *anyopaque) WalkError!WalkResult {
    switch (node.value.*) {
        .branch => |*branch| {
            const left = try walk(a, branch.left, f, ctx);
            if (!left.keep_walking) {
                var result = WalkResult{};
                result.found = left.found;
                if (left.replace) |r| result.replace = try Node.new(a, r, branch.right.retain());
                return result;
            }
            const right_result = try walk(a, branch.right, f, ctx);
            return WalkResult.merge(branch, a, left, right_result);
        },
        .leaf => |*leaf| return f(ctx, leaf),
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const RcNode = TrimmedRc(Node, usize);

pub const Node = union(enum) {
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

    ///////////////////////////// store

    pub fn toString(self: *const Node, a: Allocator, eol_mode: EolMode) ![]const u8 {
        var s = try ArrayList(u8).initCapacity(a, self.weights().len);
        try self.store(s.writer(), eol_mode);
        return s.toOwnedSlice();
    }

    test toString {
        var arena = std.heap.ArenaAllocator.init(idc_if_it_leaks);
        defer arena.deinit();

        const root = try Node.fromString(idc_if_it_leaks, &arena, "hello world");
        try eqStr("hello world", try root.value.toString(idc_if_it_leaks, .lf));

        _, _, const e1 = try insertChars(root, idc_if_it_leaks, &arena, "// ", .{ .line = 0, .col = 0 });
        try eqStr("// hello world", try e1.value.toString(idc_if_it_leaks, .lf));
    }

    pub fn store(self: *const Node, writer: anytype, eol_mode: EolMode) !void {
        switch (self.*) {
            .branch => |*branch| {
                try branch.left.value.store(writer, eol_mode);
                try branch.right.value.store(writer, eol_mode);
            },
            .leaf => |*leaf| {
                _ = try writer.write(leaf.buf);
                if (leaf.eol) switch (eol_mode) {
                    .lf => _ = try writer.write("\n"),
                    .crlf => _ = try writer.write("\r\n"),
                };
            },
        }
    }

    ///////////////////////////// Load

    pub fn fromString(a: Allocator, arena: *ArenaAllocator, source: []const u8) !RcNode {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, arena, stream.reader(), source.len);
    }

    test fromString {
        // without bol
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            const root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld");
            defer freeRcNode(testing_allocator, root);
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
};

//////////////////////////////////////////////////////////////////////////////////////////////

const InsertCharsCtx = struct {
    a: Allocator,
    col: usize,
    chars: []const u8,
    eol: bool,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        const leaf_noc = getNumOfChars(leaf.buf);

        if (ctx.col == 0) {
            const left = try Leaf.new(ctx.a, ctx.chars, leaf.bol, ctx.eol);
            const right = try Leaf.new(ctx.a, leaf.buf, ctx.eol, leaf.eol);
            return WalkResult{ .replace = try Node.new(ctx.a, left, right) };
        }

        if (leaf_noc == ctx.col) {
            if (leaf.eol and ctx.eol and ctx.chars.len == 0) {
                const left = try Leaf.new(ctx.a, leaf.buf, leaf.bol, true);
                const right = try Leaf.new(ctx.a, ctx.chars, true, true);
                return WalkResult{ .replace = try Node.new(ctx.a, left, right) };
            }

            const left = try Leaf.new(ctx.a, leaf.buf, leaf.bol, false);

            if (ctx.eol) {
                const middle = try Leaf.new(ctx.a, ctx.chars, false, ctx.eol);
                const right = try Leaf.new(ctx.a, "", ctx.eol, leaf.eol);
                const mid_right = try Node.new(ctx.a, middle, right);
                return WalkResult{ .replace = try Node.new(ctx.a, left, mid_right) };
            }

            const right = try Leaf.new(ctx.a, ctx.chars, false, leaf.eol);
            return WalkResult{ .replace = try Node.new(ctx.a, left, right) };
        }

        if (leaf_noc > ctx.col) {
            const pos = getNumOfBytesTillCol(leaf.buf, ctx.col);
            if (ctx.eol and ctx.chars.len == 0) {
                const left = try Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, ctx.eol);
                const right = try Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol);
                return WalkResult{ .replace = try Node.new(ctx.a, left, right) };
            }

            const left = try Leaf.new(ctx.a, leaf.buf[0..pos], leaf.bol, false);
            const middle = try Leaf.new(ctx.a, ctx.chars, false, ctx.eol);
            const right = try Leaf.new(ctx.a, leaf.buf[pos..], ctx.eol, leaf.eol);
            const mid_right = try Node.new(ctx.a, middle, right);
            return WalkResult{ .replace = try Node.new(ctx.a, left, mid_right) };
        }

        ctx.col -= leaf_noc;
        return if (leaf.eol) WalkResult.stop else WalkResult.keep_walking;
    }
};

const InsertCharsError = error{ OutOfMemory, InputLenZero, ColumnOutOfBounds };
pub fn insertChars(self_: RcNode, a: Allocator, content_arena: *ArenaAllocator, chars: []const u8, destination: CursorPoint) InsertCharsError!struct { usize, usize, RcNode } {
    if (chars.len == 0) return error.InputLenZero;
    var self = self_;

    var rest = try content_arena.allocator().dupe(u8, chars);
    var chunk = rest;
    var line = destination.line;
    var col = destination.col;
    var need_eol = false;

    var i: usize = 0;
    while (rest.len > 0) {
        defer i += 1;

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

        var ctx: InsertCharsCtx = .{ .a = a, .col = col, .chars = chunk, .eol = need_eol };
        const result = try walkFromLineBegin(a, self, line, InsertCharsCtx.walker, &ctx);

        if (!result.found) return error.ColumnOutOfBounds;
        if (result.replace) |root| {
            if (i > 0) freeRcNode(a, self); // prevent leaks
            self = root;
        }

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
        defer freeRcNode(testing_allocator, old_root);
        try eqStr(
            \\2 2/11
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(idc_if_it_leaks, old_root));

        {
            const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
            defer freeRcNode(testing_allocator, new_root);

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
            freeRcNode(testing_allocator, old_root);
            try eqStr(
                \\3 2/14
                \\  2 1/9
                \\    1 B| `ok `
                \\    1 `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, new_root));
        }

        // freeing new_root later
        freeRcNode(testing_allocator, new_root);
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

    freeRcNodes(testing_allocator, &.{ original, e1, e2, e3 });
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

    freeRcNodes(testing_allocator, &.{ r0, r1, r2, r3, r4, r5, r6a, r6b });

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

    freeRcNode(testing_allocator, r6c);
}

test "insertChars - abcd" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const acd = try Node.fromString(testing_allocator, &content_arena, "ACD");
    defer freeRcNode(testing_allocator, acd);

    _, _, const abcd = try insertChars(acd, testing_allocator, &content_arena, "B", .{ .line = 0, .col = 1 });
    defer freeRcNode(testing_allocator, abcd);
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
        defer freeRcNode(testing_allocator, eabcd);
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
        defer freeRcNode(testing_allocator, abcde);
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
    const l2, const c2, const r2 = try insertChars(r1, a, &content_arena, "ok", .{ .line = 1, .col = 0 });
    {
        try eqStr(
            \\3 2/12
            \\  1 B| `hello venus` Rc:2
            \\  2 1/1
            \\    1 `` |E Rc:2
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, r1));

        try eq(.{ 1, 2 }, .{ l2, c2 });
        try eqStr(
            \\4 2/14
            \\  1 B| `hello venus` Rc:2
            \\  3 1/3
            \\    1 `` |E Rc:2
            \\    2 1/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, r2));
    }

    // 3rd edit
    const l3, const c3, const r3 = try insertChars(r2, a, &content_arena, "\nfine", .{ .line = l2, .col = c2 });
    {
        try eqStr(
            \\3 2/12
            \\  1 B| `hello venus` Rc:3
            \\  2 1/1
            \\    1 `` |E Rc:3
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, r1));

        try eqStr(
            \\4 2/14
            \\  1 B| `hello venus` Rc:3
            \\  3 1/3
            \\    1 `` |E Rc:3
            \\    2 1/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, r2));

        try eq(.{ 2, 4 }, .{ l3, c3 });
        try eqStr(
            \\6 3/19
            \\  1 B| `hello venus` Rc:3
            \\  5 2/8
            \\    1 `` |E Rc:3
            \\    4 2/7
            \\      1 B| `ok`
            \\      3 1/5
            \\        1 `` |E
            \\        2 1/4
            \\          1 B| `fine`
            \\          1 ``
        , try debugStr(idc_if_it_leaks, r3));
    }

    freeRcNodes(testing_allocator, &.{ r0, r1, r2, r3 });
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
        for (0..iterations.items.len) |i| freeRcNode(testing_allocator, iterations.items[i]);
    }

    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        var iterations = try insertCharOneAfterAnother(testing_allocator, &content_arena, str);
        defer iterations.deinit();

        for (0..iterations.items.len) |i_| {
            const i = iterations.items.len - 1 - i_;
            freeRcNode(testing_allocator, iterations.items[i]);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Delete Chars

const DeleteCharsCtx = struct {
    a: Allocator,
    col: usize,
    count: usize,
    delete_next_bol: bool = false,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        var result = WalkResult.keep_walking;

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
        this_node: {
            if (ctx.col == 0) {
                if (ctx.count > leaf_noc) {
                    ctx.count -= leaf_noc;
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, false);
                    if (leaf.eol) {
                        ctx.count -= 1;
                        ctx.delete_next_bol = true;
                    }
                    break :this_node;
                }

                if (ctx.count == leaf_noc) {
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, leaf.eol);
                    ctx.count = 0;
                    break :this_node;
                }

                const pos = getNumOfBytesTillCol(leaf.buf, ctx.count);
                result.replace = try Leaf.new(ctx.a, leaf.buf[pos..], leaf_bol, leaf.eol);
                ctx.count = 0;
                break :this_node;
            }

            if (ctx.col == leaf_noc) {
                if (leaf.eol) {
                    ctx.count -= 1;
                    result.replace = try Leaf.new(ctx.a, leaf.buf, leaf_bol, false);
                    ctx.delete_next_bol = true;
                }
                ctx.col -= leaf_noc;
                break :this_node;
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
                break :this_node;
            }

            const pos_start = getNumOfBytesTillCol(leaf.buf, ctx.col);
            const pos_end = getNumOfBytesTillCol(leaf.buf, ctx.col + ctx.count);
            const left = try Leaf.new(ctx.a, leaf.buf[0..pos_start], leaf_bol, false);
            const right = try Leaf.new(ctx.a, leaf.buf[pos_end..], false, leaf.eol);
            result.replace = try Node.new(ctx.a, left, right);
            ctx.count = 0;
        }

        if (ctx.count == 0 and !ctx.delete_next_bol) result.keep_walking = false;
        return result;
    }
};

pub fn deleteChars(self: RcNode, a: Allocator, destination: CursorPoint, count: usize) error{ OutOfMemory, Stop, NotFound }!RcNode {
    var ctx = DeleteCharsCtx{ .a = a, .col = destination.col, .count = count };
    const result = try walkFromLineBegin(a, self, destination.line, DeleteCharsCtx.walker, &ctx);
    if (result.found) return result.replace orelse error.Stop;
    return error.NotFound;
}

test "deleteChars - basics" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, &content_arena, "1234567");
    defer freeRcNode(testing_allocator, original);

    {
        const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 0 }, 1);
        defer freeRcNode(testing_allocator, edit);
        try eqStr(
            \\1 B| `234567`
        , try debugStr(idc_if_it_leaks, edit));
    }

    {
        const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 3 }, 1);
        defer freeRcNode(testing_allocator, edit);
        try eqStr(
            \\2 1/6
            \\  1 B| `123`
            \\  1 `567`
        , try debugStr(idc_if_it_leaks, edit));
    }

    {
        const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
        defer freeRcNode(testing_allocator, edit);
        try eqStr(
            \\2 1/6
            \\  1 B| `12345`
            \\  1 `7`
        , try debugStr(idc_if_it_leaks, edit));
    }

    {
        const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 6 }, 1);
        defer freeRcNode(testing_allocator, edit);
        try eqStr(
            \\1 B| `123456`
        , try debugStr(idc_if_it_leaks, edit));
    }
}

test "deleteChars - multiple lines" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, &content_arena, "hello venus\nhello world\nhello kitty");
    try eqStr(
        \\3 3/35
        \\  1 B| `hello venus` |E
        \\  2 2/23
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    const e1 = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 0 }, 6);
    try eqStr(
        \\3 3/29
        \\  1 B| `venus` |E
        \\  2 2/23 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    const e2 = try deleteChars(e1, testing_allocator, .{ .line = 0, .col = 0 }, 12);
    try eqStr(
        \\3 2/17
        \\  1 B| ``
        \\  2 1/17
        \\    1 `world` |E
        \\    1 B| `hello kitty` Rc:2
    , try debugStr(idc_if_it_leaks, e2));

    freeRcNodes(testing_allocator, &.{ original, e1, e2 });
}

test "deleteChars - it leaked somehow" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, &content_arena, "hello venus\nhello world\nhello kitty");
    try eqStr(
        \\3 3/35
        \\  1 B| `hello venus` |E
        \\  2 2/23
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    const e1 = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
    try eqStr(
        \\3 3/34
        \\  2 1/11
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    try eqStr(
        \\3 3/35
        \\  1 B| `hello venus` |E
        \\  2 2/23 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    try eqStr(
        \\3 3/34
        \\  2 1/11
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    const e2 = try deleteChars(e1, testing_allocator, .{ .line = 0, .col = 0 }, 17);
    try eqStr(
        \\3 2/17
        \\  1 B| ``
        \\  2 1/17
        \\    1 `world` |E
        \\    1 B| `hello kitty` Rc:2
    , try debugStr(idc_if_it_leaks, e2));

    freeRcNodes(testing_allocator, &.{ e2, e1, original });
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Noc Of Range

const GetGetNocOfRangeCtx = struct {
    noc: usize = 0,
    curr_line: usize = undefined,
    curr_col: usize = 0,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        ctx.noc += getNumOfChars(leaf.buf);
        if (leaf.eol) {
            ctx.noc += 1;
            return WalkResult.found;
        }
        return WalkResult.keep_walking;
    }
};

pub fn getNocOfRange(node: RcNode, start: CursorPoint, end: CursorPoint) usize {
    assert(end.line >= start.line);
    assert(end.line > start.line or (start.line == end.line and start.col <= end.col));
    if (start.line == end.line) return end.col - start.col;

    var ctx = GetGetNocOfRangeCtx{};
    for (start.line..end.line + 1) |line| {
        ctx.curr_line = line;
        if (line == end.line) {
            ctx.noc += end.col;
            break;
        }
        _ = walkFromLineBegin(idc_if_it_leaks, node, line, GetGetNocOfRangeCtx.walker, &ctx) catch unreachable;
    }
    return ctx.noc - start.col;
}

test getNocOfRange {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, &content_arena, "hello venus\nhello world\nhello kitty");
    defer freeRcNode(testing_allocator, original);

    const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
    defer freeRcNode(testing_allocator, edit);
    try eqStr(
        \\3 3/34
        \\  2 1/11
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, edit));

    try eq(5, getNocOfRange(edit, .{ .line = 0, .col = 0 }, .{ .line = 0, .col = 5 }));
    try eq(5, getNocOfRange(edit, .{ .line = 0, .col = 5 }, .{ .line = 0, .col = 10 }));
    try eq(10, getNocOfRange(edit, .{ .line = 0, .col = 0 }, .{ .line = 0, .col = 10 }));

    try eq(11, getNocOfRange(edit, .{ .line = 0, .col = 0 }, .{ .line = 1, .col = 0 }));
    try eq(16, getNocOfRange(edit, .{ .line = 0, .col = 0 }, .{ .line = 1, .col = 5 }));
    try eq(11, getNocOfRange(edit, .{ .line = 0, .col = 5 }, .{ .line = 1, .col = 5 }));

    try eq(23, getNocOfRange(edit, .{ .line = 0, .col = 5 }, .{ .line = 2, .col = 5 }));
}

////////////////////////////////////////////////////////////////////////////////////////////// Balance

const MAX_IMBALANCE = 1;

fn calculateBalanceFactor(left: *const Node, right: *const Node) i64 {
    var balance_factor: i64 = @intCast(left.weights().depth);
    balance_factor -= right.weights().depth;
    return balance_factor;
}

fn isRebalanced(branch: Branch, left: RcNode, right: RcNode) bool {
    return branch.left.value != left.value or branch.right.value != right.value;
}

pub fn balance(a: Allocator, self: RcNode) !RcNode {
    switch (self.value.*) {
        .leaf => return self,
        .branch => |branch| {
            {
                const initial_balance_factor = calculateBalanceFactor(branch.left.value, branch.right.value);
                if (@abs(initial_balance_factor) < MAX_IMBALANCE) return self;
            }

            var result: RcNode = undefined;

            var left = try balance(a, branch.left);
            var right = try balance(a, branch.right);
            const balance_factor = calculateBalanceFactor(left.value, right.value);

            find_result: {
                if (@abs(balance_factor) <= MAX_IMBALANCE) {
                    result = if (isRebalanced(branch, left, right)) try Node.new(a, left.retain(), right.retain()) else self;
                    break :find_result;
                }

                if (balance_factor < 0) {
                    assert(right.value.* == .branch);
                    const right_balance_factor = calculateBalanceFactor(right.value.branch.left.value, right.value.branch.right.value);
                    if (right_balance_factor <= 0) {
                        const this = if (isRebalanced(branch, left, right)) try Node.new(a, left.retain(), right.retain()) else self;
                        result = try rotateLeft(a, this);
                        break :find_result;
                    }

                    var new_right = try rotateRight(a, right);
                    const this = try Node.new(a, left.retain(), new_right.retain());
                    result = try rotateLeft(a, this);
                    break :find_result;
                }

                assert(left.value.* == .branch);
                const left_balance_factor = calculateBalanceFactor(left.value.branch.left.value, left.value.branch.right.value);
                if (left_balance_factor >= 0) {
                    const this = if (isRebalanced(branch, left, right)) try Node.new(a, left.retain(), right.retain()) else self;
                    result = try rotateRight(a, this);
                    break :find_result;
                }

                var new_left = try rotateLeft(a, left);
                const this = try Node.new(a, new_left.retain(), right.retain());
                result = try rotateRight(a, this);
                break :find_result;
            }

            const should_balance_again = result.value.* == .branch and @abs(calculateBalanceFactor(result.value.branch.left.value, result.value.branch.right.value)) > MAX_IMBALANCE;
            if (should_balance_again) result = try balance(a, result);

            return result;
        },
    }
}

test balance {
    const a = testing_allocator;
    var content_arena = std.heap.ArenaAllocator.init(a);
    defer content_arena.deinit();

    const root = try Node.fromString(a, &content_arena, "one two three");

    _, _, const e1 = try insertChars(root, a, &content_arena, "\n", .{ .line = 0, .col = 7 });
    _, _, const e2 = try insertChars(e1, a, &content_arena, "\n", .{ .line = 0, .col = 3 });
    _, _, const e3 = try insertChars(e2, a, &content_arena, "\n", .{ .line = 0, .col = 0 });
    try eqStr(
        \\4 4/16
        \\  3 3/10
        \\    2 2/5
        \\      1 B| `` |E
        \\      1 B| `one` |E
        \\    1 B| ` two` |E Rc:2
        \\  1 B| ` three` Rc:3
    , try debugStr(idc_if_it_leaks, e3));

    const e3b = try balance(a, e3);
    try eqStr(
        \\3 4/16
        \\  2 2/5 Rc:2
        \\    1 B| `` |E
        \\    1 B| `one` |E
        \\  2 2/11
        \\    1 B| ` two` |E Rc:3
        \\    1 B| ` three` Rc:4
    , try debugStr(idc_if_it_leaks, e3b));

    freeRcNodes(a, &.{ root, e1, e2, e3, e3b });
}

fn rotateLeft(allocator: Allocator, self: RcNode) !RcNode {
    assert(self.value.* == .branch);

    const other = self.value.branch.right;
    assert(other.value.* == .branch);

    const a = try Node.new(allocator, self.value.branch.left.retain(), other.value.branch.left.retain());
    const b = try Node.new(allocator, a, other.value.branch.right.retain());
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
        \\    1 B| `A` Rc:3
        \\    1 `B` Rc:3
        \\  2 0/3 Rc:2
        \\    1 `CD`
        \\    1 `E`
    ;
    try eqStr(abcde_rotated_dbg, try debugStr(idc_if_it_leaks, abcde_rotated));

    freeRcNodes(testing_allocator, &.{ acd, abcd, abcde, abcde_rotated });
}

fn rotateRight(allocator: Allocator, self: RcNode) !RcNode {
    assert(self.value.* == .branch);

    const other = self.value.branch.left;
    assert(other.value.* == .branch);

    const a = try Node.new(allocator, other.value.branch.right.retain(), self.value.branch.right.retain());
    const b = try Node.new(allocator, other.value.branch.left.retain(), a);
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
        \\  1 B| `_` Rc:2
        \\  2 0/4
        \\    1 `ABC` Rc:2
        \\    1 `D` Rc:3
    ;
    try eqStr(_abcd_rotated_dbg, try debugStr(idc_if_it_leaks, _abcd_rotated));

    freeRcNodes(testing_allocator, &.{ abc, abcd, _abcd, _abcd_rotated });
}

////////////////////////////////////////////////////////////////////////////////////////////// Debug

pub fn debugStr(a: Allocator, node: RcNode) ![]const u8 {
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

//////////////////////////////////////////////////////////////////////////////////////////////

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

pub const CursorPoint = struct {
    line: usize,
    col: usize,

    pub fn cmp(_: void, a: CursorPoint, b: CursorPoint) bool {
        if (a.line < b.line) return true;
        if (a.line == b.line and a.col < b.col) return true;
        return false;
    }
};

pub const CursorRange = struct {
    start: CursorPoint,
    end: CursorPoint,

    pub fn cmp(_: void, a: CursorRange, b: CursorRange) bool {
        assert(std.sort.isSorted(CursorPoint, &.{ a.start, a.end }, {}, CursorPoint.cmp));
        assert(std.sort.isSorted(CursorPoint, &.{ b.start, b.end }, {}, CursorPoint.cmp));

        if (a.start.line < b.start.line) return true;
        if (a.start.line == b.start.line) {
            if (a.start.col < b.start.col) return true;
            if (a.end.line < b.end.line) return true;
            if (a.end.line == b.end.line and a.end.col < b.end.col) return true;
        }

        return false;
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

pub fn getNumOfChars(str: []const u8) u32 {
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

test "size matters" {
    try eq(8, @alignOf(Leaf));
    try eq(8, @alignOf(Branch));
    try eq(4, @alignOf(Weights));
    try eq(8, @alignOf(Node));

    try eq(12, @sizeOf(Weights));
    try eq(24, @sizeOf(Leaf));
    try eq(32, @sizeOf(Branch));
    try eq(40, @sizeOf(Node));

    try eq(8, @alignOf(RcNode));
    try eq(8, RcNode.innerAlign());

    try eq(8, @sizeOf(RcNode));
    try eq(48, RcNode.innerSize());
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn freeRcNodes(a: Allocator, nodes: []const RcNode) void {
    for (nodes) |node| freeRcNode(a, node);
}

pub fn freeRcNode(a: Allocator, node: RcNode) void {
    releaseChildrenRecursive(node.value, a);
    node.release(a);
}

fn releaseChildrenRecursive(self: *const Node, a: Allocator) void {
    if (self.* == .leaf) return;
    if (self.branch.left.strongCount() == 1) releaseChildrenRecursive(self.branch.left.value, a);
    self.branch.left.release(a);
    if (self.branch.right.strongCount() == 1) releaseChildrenRecursive(self.branch.right.value, a);
    self.branch.right.release(a);
}
