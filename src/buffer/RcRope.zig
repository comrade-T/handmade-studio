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
const ztracy = @import("ztracy");
const rc = @import("zigrc");
pub const code_point = @import("code_point");

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
const shouldErr = std.testing.expectError;

pub const EolMode = enum { lf, crlf };

//////////////////////////////////////////////////////////////////////////////////////////////

const WalkError = error{OutOfMemory};
const WalkCallback = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkError!WalkResult;

const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkError!WalkResult;
const DC = *const fn (ctx: *anyopaque, decrement_col_by: usize) void;

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
                if (new_left_is_replace) new_left.release(a);
                break :replace;
            }

            if (new_right.value.isEmpty()) {
                result.replace = new_left;
                if (new_right_is_replace) new_right.release(a);
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

    pub fn weights(self: *const Node) Weights {
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
        const zone = ztracy.ZoneNC(@src(), "Node.toString()", 0xF55555);
        defer zone.End();

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

    pub fn fromFile(a: Allocator, arena: *ArenaAllocator, path: []const u8) !RcNode {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        return Node.fromReader(a, arena, file.reader(), stat.size);
    }

    test fromString {
        // without bol
        {
            var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
            defer content_arena.deinit();
            const root = try Node.fromString(testing_allocator, &content_arena, "hello\nworld");
            defer freeRcNode(testing_allocator, root);
            try eqStr(
                \\2 2/11/10
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
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "", .noc = 0 }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "\n");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "", .noc = 0 }, leaves[0].value.leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "hello\nworld");
            try eq(2, leaves.len);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "hello", .noc = 5 }, leaves[0].value.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world", .noc = 5 }, leaves[1].value.leaf);
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

        if (ctx.col == 0) {
            const left = try Leaf.new(ctx.a, ctx.chars, leaf.bol, ctx.eol);
            const right = try Leaf.new(ctx.a, leaf.buf, ctx.eol, leaf.eol);
            return WalkResult{ .replace = try Node.new(ctx.a, left, right) };
        }

        if (leaf.noc == ctx.col) {
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

        if (leaf.noc > ctx.col) {
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

        ctx.col -= leaf.noc;
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
            \\2 2/11/10
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(idc_if_it_leaks, old_root));

        {
            const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
            defer freeRcNode(testing_allocator, new_root);

            try eqStr(
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, old_root));

            try eq(.{ 0, 3 }, .{ line, col });
            try eqStr(
                \\3 2/14/13
                \\  2 1/9/8
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
            \\2 2/11/10
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(idc_if_it_leaks, old_root));

        // after insertChars()
        const line, const col, const new_root = try insertChars(old_root, testing_allocator, &content_arena, "ok ", .{ .line = 0, .col = 0 });
        {
            try eqStr(
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, old_root));

            try eq(.{ 0, 3 }, .{ line, col });
            try eqStr(
                \\3 2/14/13
                \\  2 1/9/8
                \\    1 B| `ok `
                \\    1 `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, new_root));
        }

        // freeing old_root first
        {
            freeRcNode(testing_allocator, old_root);
            try eqStr(
                \\3 2/14/13
                \\  2 1/9/8
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
        \\3 1/6/6
        \\  1 B| `he`
        \\  2 0/4/4
        \\    1 `3`
        \\    1 `llo`
    , try debugStr(idc_if_it_leaks, e1));

    // `he3llo` -> `he3ll0o`
    const l2, const c2, const e2 = try insertChars(e1, testing_allocator, &content_arena, "0", .{ .line = 0, .col = 5 });
    try eq(.{ 0, 6 }, .{ l2, c2 });
    try eqStr(
        \\5 1/7/7
        \\  1 B| `he` Rc:2
        \\  4 0/5/5
        \\    1 `3` Rc:2
        \\    3 0/4/4
        \\      1 `ll`
        \\      2 0/2/2
        \\        1 `0`
        \\        1 `o`
    , try debugStr(idc_if_it_leaks, e2));

    // `he3ll0o` -> `he3ll\n0o`
    const l3, const c3, const e3 = try insertChars(e2, testing_allocator, &content_arena, "\n", .{ .line = 0, .col = 5 });
    try eq(.{ 1, 0 }, .{ l3, c3 });
    try eqStr(
        \\6 2/8/7
        \\  1 B| `he` Rc:3
        \\  5 1/6/5
        \\    1 `3` Rc:3
        \\    4 1/5/4
        \\      3 1/3/2
        \\        1 `ll`
        \\        2 1/1/0
        \\          1 `` |E
        \\          1 B| ``
        \\      2 0/2/2 Rc:2
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
            \\2 1/1/1
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
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, r1));

        try eq(.{ 0, 2 }, .{ l2, c2 });
        try eqStr(
            \\2 1/2/2
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
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, r1));

        try eqStr(
            \\2 1/2/2
            \\  1 B| `h` Rc:2
            \\  1 `e`
        , try debugStr(idc_if_it_leaks, r2));

        try eq(.{ 0, 3 }, .{ l3, c3 });
        try eqStr(
            \\3 1/3/3
            \\  1 B| `h` Rc:2
            \\  2 0/2/2
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
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, r1));

        try eqStr(
            \\2 1/2/2
            \\  1 B| `h` Rc:2
            \\  1 `e`
        , try debugStr(idc_if_it_leaks, r2));

        try eqStr(
            \\3 1/3/3
            \\  1 B| `h` Rc:2
            \\  2 0/2/2 Rc:2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, r3));

        try eq(.{ 0, 2 }, .{ l4, c4 });
        try eqStr(
            \\3 1/4/4
            \\  2 1/2/2
            \\    1 B| `h`
            \\    1 `3`
            \\  2 0/2/2 Rc:2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, r4));
    }

    const l5, const c5, const r5 = try insertChars(r4, a, &content_arena, "// ", .{ .line = 0, .col = 0 });
    {
        try eq(.{ 0, 3 }, .{ l5, c5 });
        try eqStr(
            \\4 1/7/7
            \\  3 1/5/5
            \\    2 1/4/4
            \\      1 B| `// `
            \\      1 `h`
            \\    1 `3` Rc:2
            \\  2 0/2/2 Rc:3
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, r5));
    }

    const l6a, const c6a, const r6a = try insertChars(r5, a, &content_arena, "o", .{ .line = 0, .col = 7 });
    {
        try eq(.{ 0, 8 }, .{ l6a, c6a });
        try eqStr( // h3elo
            \\4 1/8/8
            \\  3 1/5/5 Rc:2
            \\    2 1/4/4
            \\      1 B| `// `
            \\      1 `h`
            \\    1 `3` Rc:2
            \\  3 0/3/3
            \\    1 `e` Rc:2
            \\    2 0/2/2
            \\      1 `l`
            \\      1 `o`
        , try debugStr(idc_if_it_leaks, r6a));
    }

    const l6b, const c6b, const r6b = try insertChars(r5, a, &content_arena, "x", .{ .line = 0, .col = 6 });
    {
        try eq(.{ 0, 7 }, .{ l6b, c6b });
        try eqStr( // h3exl
            \\4 1/8/8
            \\  3 1/5/5 Rc:3
            \\    2 1/4/4
            \\      1 B| `// `
            \\      1 `h`
            \\    1 `3` Rc:2
            \\  3 0/3/3
            \\    2 0/2/2
            \\      1 `e`
            \\      1 `x`
            \\    1 `l` Rc:2
        , try debugStr(idc_if_it_leaks, r6b));
    }

    const l6c, const c6c, const r6c = try insertChars(r5, a, &content_arena, "x", .{ .line = 0, .col = 5 });
    {
        try eq(.{ 0, 6 }, .{ l6c, c6c });
        try eqStr( // h3xel
            \\4 1/8/8
            \\  3 1/6/6
            \\    2 1/4/4 Rc:2
            \\      1 B| `// `
            \\      1 `h`
            \\    2 0/2/2
            \\      1 `3`
            \\      1 `x`
            \\  2 0/2/2 Rc:4
            \\    1 `e` Rc:2
            \\    1 `l` Rc:2
        , try debugStr(idc_if_it_leaks, r6c));
    }

    freeRcNodes(testing_allocator, &.{ r0, r1, r2, r3, r4, r5, r6a, r6b });

    try eqStr( // h3xel
        \\4 1/8/8
        \\  3 1/6/6
        \\    2 1/4/4
        \\      1 B| `// `
        \\      1 `h`
        \\    2 0/2/2
        \\      1 `3`
        \\      1 `x`
        \\  2 0/2/2
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
        \\3 1/4/4
        \\  1 B| `A`
        \\  2 0/3/3
        \\    1 `B`
        \\    1 `CD`
    ;
    try eqStr(abcd_dbg, try debugStr(idc_if_it_leaks, abcd));

    {
        _, _, const eabcd = try insertChars(abcd, testing_allocator, &content_arena, "E", .{ .line = 0, .col = 0 });
        defer freeRcNode(testing_allocator, eabcd);
        const eabcd_dbg =
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `E`
            \\    1 `A`
            \\  2 0/3/3 Rc:2
            \\    1 `B`
            \\    1 `CD`
        ;
        try eqStr(eabcd_dbg, try debugStr(idc_if_it_leaks, eabcd));
    }

    {
        _, _, const abcde = try insertChars(abcd, testing_allocator, &content_arena, "E", .{ .line = 0, .col = 4 });
        defer freeRcNode(testing_allocator, abcde);
        const abcde_dbg =
            \\4 1/5/5
            \\  1 B| `A` Rc:2
            \\  3 0/4/4
            \\    1 `B` Rc:2
            \\    2 0/3/3
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
            \\3 2/12/11
            \\  1 B| `hello venus`
            \\  2 1/1/0
            \\    1 `` |E
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, r1));
    }

    // 2nd edit
    const l2, const c2, const r2 = try insertChars(r1, a, &content_arena, "ok", .{ .line = 1, .col = 0 });
    {
        try eqStr(
            \\3 2/12/11
            \\  1 B| `hello venus` Rc:2
            \\  2 1/1/0
            \\    1 `` |E Rc:2
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, r1));

        try eq(.{ 1, 2 }, .{ l2, c2 });
        try eqStr(
            \\4 2/14/13
            \\  1 B| `hello venus` Rc:2
            \\  3 1/3/2
            \\    1 `` |E Rc:2
            \\    2 1/2/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, r2));
    }

    // 3rd edit
    const l3, const c3, const r3 = try insertChars(r2, a, &content_arena, "\nfine", .{ .line = l2, .col = c2 });
    {
        try eqStr(
            \\3 2/12/11
            \\  1 B| `hello venus` Rc:3
            \\  2 1/1/0
            \\    1 `` |E Rc:3
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, r1));

        try eqStr(
            \\4 2/14/13
            \\  1 B| `hello venus` Rc:3
            \\  3 1/3/2
            \\    1 `` |E Rc:3
            \\    2 1/2/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, r2));

        try eq(.{ 2, 4 }, .{ l3, c3 });
        try eqStr(
            \\6 3/19/17
            \\  1 B| `hello venus` Rc:3
            \\  5 2/8/6
            \\    1 `` |E Rc:3
            \\    4 2/7/6
            \\      1 B| `ok`
            \\      3 1/5/4
            \\        1 `` |E
            \\        2 1/4/4
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

        const leaf_bol = leaf.bol and !ctx.delete_next_bol;
        ctx.delete_next_bol = false;

        // next node
        if (ctx.col > leaf.noc) {
            ctx.col -= leaf.noc;
            if (leaf.eol) ctx.col -= 1;
            return result;
        }

        // this node
        this_node: {
            if (ctx.col == 0) {
                if (ctx.count > leaf.noc) {
                    ctx.count -= leaf.noc;
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, false);
                    if (leaf.eol) {
                        ctx.count -= 1;
                        ctx.delete_next_bol = true;
                    }
                    break :this_node;
                }

                if (ctx.count == leaf.noc) {
                    result.replace = try Leaf.new(ctx.a, "", leaf_bol, leaf.eol);
                    ctx.count = 0;
                    break :this_node;
                }

                const pos = getNumOfBytesTillCol(leaf.buf, ctx.count);
                result.replace = try Leaf.new(ctx.a, leaf.buf[pos..], leaf_bol, leaf.eol);
                ctx.count = 0;
                break :this_node;
            }

            if (ctx.col == leaf.noc) {
                if (leaf.eol) {
                    ctx.count -= 1;
                    result.replace = try Leaf.new(ctx.a, leaf.buf, leaf_bol, false);
                    ctx.delete_next_bol = true;
                }
                ctx.col -= leaf.noc;
                break :this_node;
            }

            if (ctx.col + ctx.count >= leaf.noc) {
                ctx.count -= leaf.noc - ctx.col;
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
    assert(count > 0);
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
            \\2 1/6/6
            \\  1 B| `123`
            \\  1 `567`
        , try debugStr(idc_if_it_leaks, edit));
    }

    {
        const edit = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
        defer freeRcNode(testing_allocator, edit);
        try eqStr(
            \\2 1/6/6
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
        \\3 3/35/33
        \\  1 B| `hello venus` |E
        \\  2 2/23/22
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    const e1 = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 0 }, 6);
    try eqStr(
        \\3 3/29/27
        \\  1 B| `venus` |E
        \\  2 2/23/22 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    const e2 = try deleteChars(e1, testing_allocator, .{ .line = 0, .col = 0 }, 12);
    try eqStr(
        \\3 2/17/16
        \\  1 B| ``
        \\  2 1/17/16
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
        \\3 3/35/33
        \\  1 B| `hello venus` |E
        \\  2 2/23/22
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    const e1 = try deleteChars(original, testing_allocator, .{ .line = 0, .col = 5 }, 1);
    try eqStr(
        \\3 3/34/32
        \\  2 1/11/10
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23/22 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    try eqStr(
        \\3 3/35/33
        \\  1 B| `hello venus` |E
        \\  2 2/23/22 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, original));

    try eqStr(
        \\3 3/34/32
        \\  2 1/11/10
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23/22 Rc:2
        \\    1 B| `hello world` |E
        \\    1 B| `hello kitty`
    , try debugStr(idc_if_it_leaks, e1));

    const e2 = try deleteChars(e1, testing_allocator, .{ .line = 0, .col = 0 }, 17);
    try eqStr(
        \\3 2/17/16
        \\  1 B| ``
        \\  2 1/17/16
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
        \\3 3/34/32
        \\  2 1/11/10
        \\    1 B| `hello`
        \\    1 `venus` |E
        \\  2 2/23/22 Rc:2
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

pub fn balance(a: Allocator, self: RcNode) !struct { bool, RcNode } {
    switch (self.value.*) {
        .leaf => return .{ false, self },
        .branch => |branch| {
            {
                const initial_balance_factor = calculateBalanceFactor(branch.left.value, branch.right.value);
                if (@abs(initial_balance_factor) <= MAX_IMBALANCE) return .{ false, self };
            }

            var result: RcNode = undefined;
            const has_changes = true;

            const left_changed, var left = try balance(a, branch.left);
            const right_changed, var right = try balance(a, branch.right);
            const balance_factor = calculateBalanceFactor(left.value, right.value);

            find_result: {
                if (@abs(balance_factor) <= MAX_IMBALANCE) {
                    result = try Node.new(
                        a,
                        if (!left_changed) left.retain() else left,
                        if (!right_changed) right.retain() else right,
                    );
                    break :find_result;
                }

                if (balance_factor < 0) {
                    assert(right.value.* == .branch);
                    const right_balance_factor = calculateBalanceFactor(right.value.branch.left.value, right.value.branch.right.value);
                    if (right_balance_factor <= 0) {
                        if (left_changed or right_changed) {
                            const temp = try Node.new(
                                a,
                                if (!left_changed) left.retain() else left,
                                if (!right_changed) right.retain() else right,
                            );
                            defer freeRcNode(a, temp);
                            result = try rotateLeft(a, temp);
                            break :find_result;
                        }
                        result = try rotateLeft(a, self);
                        break :find_result;
                    }

                    const new_right = try rotateRight(a, right);
                    defer if (right_changed) freeRcNode(a, right);
                    const temp = try Node.new(a, if (!left_changed) left.retain() else left, new_right);
                    defer freeRcNode(a, temp);
                    result = try rotateLeft(a, temp);
                    break :find_result;
                }

                assert(left.value.* == .branch);
                const left_balance_factor = calculateBalanceFactor(left.value.branch.left.value, left.value.branch.right.value);
                if (left_balance_factor >= 0) {
                    if (left_changed or right_changed) {
                        const temp = try Node.new(
                            a,
                            if (!left_changed) left.retain() else left,
                            if (!right_changed) right.retain() else right,
                        );
                        defer freeRcNode(a, temp);
                        result = try rotateRight(a, temp);
                        break :find_result;
                    }

                    result = try rotateRight(a, self);
                    break :find_result;
                }

                const new_left = try rotateLeft(a, left);
                defer if (left_changed) freeRcNode(a, left);
                const temp = try Node.new(a, new_left, if (!right_changed) right.retain() else right);
                defer freeRcNode(a, temp);
                result = try rotateRight(a, temp);
                break :find_result;
            }

            return .{ has_changes, result };
        },
    }
}

test balance {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const root = try Node.fromString(testing_allocator, &content_arena, "");

    _, _, const e1 = try insertChars(root, testing_allocator, &content_arena, "1", .{ .line = 0, .col = 0 });
    try eq(.{ false, e1 }, try balance(testing_allocator, e1));

    _, _, const e2 = try insertChars(e1, testing_allocator, &content_arena, "2", .{ .line = 0, .col = 1 });
    try eq(.{ false, e1 }, try balance(testing_allocator, e1));

    _, _, const e3 = try insertChars(e2, testing_allocator, &content_arena, "3", .{ .line = 0, .col = 2 });
    try eq(.{ false, e1 }, try balance(testing_allocator, e1));

    ///////////////////////////// e4

    _, _, const e4 = try insertChars(e3, testing_allocator, &content_arena, "4", .{ .line = 0, .col = 3 });
    try eqStr( // unbalanced
        \\4 1/4/4
        \\  1 B| `1` Rc:3
        \\  3 0/3/3
        \\    1 `2` Rc:2
        \\    2 0/2/2
        \\      1 `3`
        \\      1 `4`
    , try debugStr(idc_if_it_leaks, e4));

    const e4_has_changes, const e4_balanced = try balance(testing_allocator, e4);
    {
        try eq(true, e4_has_changes);
        try eqStr(
            \\3 1/4/4
            \\  2 1/2/2
            \\    1 B| `1` Rc:4
            \\    1 `2` Rc:3
            \\  2 0/2/2 Rc:2
            \\    1 `3`
            \\    1 `4`
        , try debugStr(idc_if_it_leaks, e4_balanced));
    }

    ///////////////////////////// e5

    _, _, const e5 = try insertChars(e4, testing_allocator, &content_arena, "5", .{ .line = 0, .col = 4 });
    try eqStr( // unbalanced
        \\5 1/5/5
        \\  1 B| `1` Rc:5
        \\  4 0/4/4
        \\    1 `2` Rc:4
        \\    3 0/3/3
        \\      1 `3` Rc:2
        \\      2 0/2/2
        \\        1 `4`
        \\        1 `5`
    , try debugStr(idc_if_it_leaks, e5));

    const e5_has_changes, const e5_balanced = try balance(testing_allocator, e5);
    {
        try eq(true, e5_has_changes);
        try eqStr(
            \\4 1/5/5
            \\  3 1/3/3
            \\    1 B| `1` Rc:6
            \\    2 0/2/2
            \\      1 `2` Rc:5
            \\      1 `3` Rc:3
            \\  2 0/2/2 Rc:2
            \\    1 `4`
            \\    1 `5`
        , try debugStr(idc_if_it_leaks, e5_balanced));
    }

    ///////////////////////////// e6

    _, _, const e6 = try insertChars(e5, testing_allocator, &content_arena, "6", .{ .line = 0, .col = 5 });
    try eqStr( // unbalanced
        \\6 1/6/6
        \\  1 B| `1` Rc:7
        \\  5 0/5/5
        \\    1 `2` Rc:6
        \\    4 0/4/4
        \\      1 `3` Rc:4
        \\      3 0/3/3
        \\        1 `4` Rc:2
        \\        2 0/2/2
        \\          1 `5`
        \\          1 `6`
    , try debugStr(idc_if_it_leaks, e6));

    const e6_has_changes, const e6_balanced = try balance(testing_allocator, e6);
    {
        try eq(true, e6_has_changes);
        try eqStr(
            \\4 1/6/6
            \\  2 1/2/2
            \\    1 B| `1` Rc:8
            \\    1 `2` Rc:7
            \\  3 0/4/4
            \\    2 0/2/2
            \\      1 `3` Rc:5
            \\      1 `4` Rc:3
            \\    2 0/2/2 Rc:2
            \\      1 `5`
            \\      1 `6`
        , try debugStr(idc_if_it_leaks, e6_balanced));
    }

    freeRcNodes(testing_allocator, &.{ root, e1, e2, e3, e4, e4_balanced, e5, e5_balanced, e6, e6_balanced });
}

test "insert at beginning then balance, one character at a time" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const root = try Node.fromString(testing_allocator, &content_arena, "hello world");

    _, _, const e1 = try insertChars(root, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    try eq(.{ false, e1 }, try balance(testing_allocator, e1));

    _, _, const e2 = try insertChars(e1, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    try eq(.{ false, e2 }, try balance(testing_allocator, e2));

    ///////////////////////////// e3

    _, _, const e3 = try insertChars(e2, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNodes(testing_allocator, &.{ root, e1, e2 });
    try eqStr(
        \\4 1/14/14
        \\  3 1/3/3
        \\    2 1/2/2
        \\      1 B| `/`
        \\      1 `/`
        \\    1 `/`
        \\  1 `hello world`
    , try debugStr(idc_if_it_leaks, e3));

    const e3_rebalanced, const e3b = try balance(testing_allocator, e3);
    {
        try eq(true, e3_rebalanced);
        freeRcNode(testing_allocator, e3);
        try eqStr(
            \\3 1/14/14
            \\  2 1/2/2
            \\    1 B| `/`
            \\    1 `/`
            \\  2 0/12/12
            \\    1 `/`
            \\    1 `hello world`
        , try debugStr(idc_if_it_leaks, e3b));
    }

    ///////////////////////////// e4

    _, _, const e4 = try insertChars(e3b, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e3b);
    try eqStr(
        \\4 1/15/15
        \\  3 1/3/3
        \\    2 1/2/2
        \\      1 B| `/`
        \\      1 `/`
        \\    1 `/`
        \\  2 0/12/12
        \\    1 `/`
        \\    1 `hello world`
    , try debugStr(idc_if_it_leaks, e4));

    const e4_rebalanced, _ = try balance(testing_allocator, e4);
    try eq(false, e4_rebalanced);

    ///////////////////////////// e5

    _, _, const e5 = try insertChars(e4, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e4);
    try eqStr(
        \\5 1/16/16
        \\  4 1/4/4
        \\    3 1/3/3
        \\      2 1/2/2
        \\        1 B| `/`
        \\        1 `/`
        \\      1 `/`
        \\    1 `/`
        \\  2 0/12/12
        \\    1 `/`
        \\    1 `hello world`
    , try debugStr(idc_if_it_leaks, e5));

    const e5_rebalanced, const e5b = try balance(testing_allocator, e5);
    {
        try eq(true, e5_rebalanced);
        freeRcNode(testing_allocator, e5);
        try eqStr(
            \\4 1/16/16
            \\  3 1/4/4
            \\    2 1/2/2
            \\      1 B| `/`
            \\      1 `/`
            \\    2 0/2/2
            \\      1 `/`
            \\      1 `/`
            \\  2 0/12/12
            \\    1 `/`
            \\    1 `hello world`
        , try debugStr(idc_if_it_leaks, e5b));
    }

    ///////////////////////////// e6

    _, _, const e6 = try insertChars(e5b, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e5b);
    try eqStr(
        \\5 1/17/17
        \\  4 1/5/5
        \\    3 1/3/3
        \\      2 1/2/2
        \\        1 B| `/`
        \\        1 `/`
        \\      1 `/`
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\  2 0/12/12
        \\    1 `/`
        \\    1 `hello world`
    , try debugStr(idc_if_it_leaks, e6));

    const e6_rebalanced, const e6b = try balance(testing_allocator, e6);
    {
        try eq(true, e6_rebalanced);
        freeRcNode(testing_allocator, e6);
        try eqStr(
            \\4 1/17/17
            \\  3 1/3/3
            \\    2 1/2/2
            \\      1 B| `/`
            \\      1 `/`
            \\    1 `/`
            \\  3 0/14/14
            \\    2 0/2/2
            \\      1 `/`
            \\      1 `/`
            \\    2 0/12/12
            \\      1 `/`
            \\      1 `hello world`
        , try debugStr(idc_if_it_leaks, e6b));
    }

    ///////////////////////////// e7

    _, _, const e7 = try insertChars(e6b, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e6b);
    // We can clearly see the imbalance `3 vs 1`.
    // I'll leave it there for now, see if it resolves itself after a few more balances.
    try eqStr(
        \\5 1/18/18
        \\  4 1/4/4
        \\    3 1/3/3
        \\      2 1/2/2
        \\        1 B| `/`
        \\        1 `/`
        \\      1 `/`
        \\    1 `/`
        \\  3 0/14/14
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\    2 0/12/12
        \\      1 `/`
        \\      1 `hello world`
    , try debugStr(idc_if_it_leaks, e7));

    const e7_rebalanced, _ = try balance(testing_allocator, e7);
    try eq(false, e7_rebalanced);

    ///////////////////////////// e8

    _, _, const e8 = try insertChars(e7, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e7);
    try eqStr(
        \\6 1/19/19
        \\  5 1/5/5
        \\    4 1/4/4
        \\      3 1/3/3
        \\        2 1/2/2
        \\          1 B| `/`
        \\          1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    1 `/`
        \\  3 0/14/14
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\    2 0/12/12
        \\      1 `/`
        \\      1 `hello world`
    , try debugStr(idc_if_it_leaks, e8));

    const e8_rebalanced, const e8b = try balance(testing_allocator, e8);
    {
        try eq(true, e8_rebalanced);
        freeRcNode(testing_allocator, e8);
        try eqStr(
            \\5 1/19/19
            \\  4 1/5/5
            \\    2 1/2/2
            \\      1 B| `/`
            \\      1 `/`
            \\    3 0/3/3
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      1 `/`
            \\  3 0/14/14
            \\    2 0/2/2
            \\      1 `/`
            \\      1 `/`
            \\    2 0/12/12
            \\      1 `/`
            \\      1 `hello world`
        , try debugStr(idc_if_it_leaks, e8b));
    }

    ///////////////////////////// e9

    _, _, const e9 = try insertChars(e8b, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e8b);
    try eqStr(
        \\5 1/20/20
        \\  4 1/6/6
        \\    3 1/3/3
        \\      2 1/2/2
        \\        1 B| `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\  3 0/14/14
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\    2 0/12/12
        \\      1 `/`
        \\      1 `hello world`
    , try debugStr(idc_if_it_leaks, e9));

    const e9_rebalanced, _ = try balance(testing_allocator, e9);
    try eq(false, e9_rebalanced);

    ///////////////////////////// e10

    _, _, const e10 = try insertChars(e9, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e9);
    try eqStr(
        \\6 1/21/21
        \\  5 1/7/7
        \\    4 1/4/4
        \\      3 1/3/3
        \\        2 1/2/2
        \\          1 B| `/`
        \\          1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\  3 0/14/14
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\    2 0/12/12
        \\      1 `/`
        \\      1 `hello world`
    , try debugStr(idc_if_it_leaks, e10));

    const e10_rebalanced, const e10b = try balance(testing_allocator, e10);
    {
        try eq(true, e10_rebalanced);
        freeRcNode(testing_allocator, e10);
        try eqStr(
            \\5 1/21/21
            \\  4 1/4/4
            \\    3 1/3/3
            \\      2 1/2/2
            \\        1 B| `/`
            \\        1 `/`
            \\      1 `/`
            \\    1 `/`
            \\  4 0/17/17
            \\    3 0/3/3
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      1 `/`
            \\    3 0/14/14
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      2 0/12/12
            \\        1 `/`
            \\        1 `hello world`
        , try debugStr(idc_if_it_leaks, e10b));
    }

    ///////////////////////////// e11

    _, _, const e11 = try insertChars(e10b, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e10b);
    try eqStr(
        \\6 1/22/22
        \\  5 1/5/5
        \\    4 1/4/4
        \\      3 1/3/3
        \\        2 1/2/2
        \\          1 B| `/`
        \\          1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    1 `/`
        \\  4 0/17/17
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/14/14
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      2 0/12/12
        \\        1 `/`
        \\        1 `hello world`
    , try debugStr(idc_if_it_leaks, e11));

    const e11_rebalanced, _ = try balance(testing_allocator, e9);
    try eq(false, e11_rebalanced);

    ///////////////////////////// e12

    _, _, const e12 = try insertChars(e11, testing_allocator, &content_arena, "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e11);
    try eqStr(
        \\7 1/23/23
        \\  6 1/6/6
        \\    5 1/5/5
        \\      4 1/4/4
        \\        3 1/3/3
        \\          2 1/2/2
        \\            1 B| `/`
        \\            1 `/`
        \\          1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    1 `/`
        \\  4 0/17/17
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/14/14
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      2 0/12/12
        \\        1 `/`
        \\        1 `hello world`
    , try debugStr(idc_if_it_leaks, e12));

    const e12_rebalanced, const e12b = try balance(testing_allocator, e12);
    {
        try eq(true, e12_rebalanced);
        freeRcNode(testing_allocator, e12);
        try eqStr(
            \\5 1/23/23
            \\  4 1/6/6
            \\    3 1/4/4
            \\      2 1/2/2
            \\        1 B| `/`
            \\        1 `/`
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\    2 0/2/2
            \\      1 `/`
            \\      1 `/`
            \\  4 0/17/17
            \\    3 0/3/3
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      1 `/`
            \\    3 0/14/14
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      2 0/12/12
            \\        1 `/`
            \\        1 `hello world`
        , try debugStr(idc_if_it_leaks, e12b));
    }

    ///////////////////////////// e13

    _, _, const e13 = try insertChars(e12b, testing_allocator, &content_arena, "a", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e12b);
    try eqStr(
        \\6 1/24/24
        \\  5 1/7/7
        \\    4 1/5/5
        \\      3 1/3/3
        \\        2 1/2/2
        \\          1 B| `a`
        \\          1 `/`
        \\        1 `/`
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\  4 0/17/17
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/14/14
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      2 0/12/12
        \\        1 `/`
        \\        1 `hello world`
    , try debugStr(idc_if_it_leaks, e13));

    const e13_rebalanced, _ = try balance(testing_allocator, e13);
    try eq(false, e13_rebalanced);

    ///////////////////////////// e14

    _, _, const e14 = try insertChars(e13, testing_allocator, &content_arena, "a", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, e13);
    try eqStr(
        \\7 1/25/25
        \\  6 1/8/8
        \\    5 1/6/6
        \\      4 1/4/4
        \\        3 1/3/3
        \\          2 1/2/2
        \\            1 B| `a`
        \\            1 `a`
        \\          1 `/`
        \\        1 `/`
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\    2 0/2/2
        \\      1 `/`
        \\      1 `/`
        \\  4 0/17/17
        \\    3 0/3/3
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      1 `/`
        \\    3 0/14/14
        \\      2 0/2/2
        \\        1 `/`
        \\        1 `/`
        \\      2 0/12/12
        \\        1 `/`
        \\        1 `hello world`
    , try debugStr(idc_if_it_leaks, e14));

    const e14_rebalanced, const e14b = try balance(testing_allocator, e14);
    {
        try eq(true, e14_rebalanced);
        freeRcNode(testing_allocator, e14);
        try eqStr(
            \\5 1/25/25
            \\  4 1/8/8
            \\    3 1/4/4
            \\      2 1/2/2
            \\        1 B| `a`
            \\        1 `a`
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\    3 0/4/4
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\  4 0/17/17
            \\    3 0/3/3
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      1 `/`
            \\    3 0/14/14
            \\      2 0/2/2
            \\        1 `/`
            \\        1 `/`
            \\      2 0/12/12
            \\        1 `/`
            \\        1 `hello world`
        , try debugStr(idc_if_it_leaks, e14b));
    }

    /////////////////////////////

    freeRcNode(testing_allocator, e14b);
}

test "insert 'a' one after another to a string" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const root = try Node.fromFile(testing_allocator, &content_arena, "src/window/fixtures/dummy_3_lines.zig");

    var list = ArrayList(RcNode).init(testing_allocator);
    defer list.deinit();

    ///////////////////////////// e1

    const e1line, const e1col, const e1 = try insertChars(root, testing_allocator, &content_arena, "1", .{ .line = 0, .col = 0 });
    try list.append(root);
    try eqStr(
        \\4 4/74/71
        \\  3 2/37/35
        \\    2 1/15/14
        \\      1 B| `1`
        \\      1 `const a = 10;` |E
        \\    1 B| `var not_false = true;` |E Rc:2
        \\  2 2/37/36 Rc:2
        \\    1 B| `const Allocator = std.mem.Allocator;` |E
        \\    1 B| ``
    , try debugStr(idc_if_it_leaks, e1));

    try eq(.{ false, e1 }, try balance(testing_allocator, e1));

    ///////////////////////////// e2

    const e2line, const e2col, const e2 = try insertChars(e1, testing_allocator, &content_arena, "2", .{ .line = e1line, .col = e1col });
    try list.append(e1);
    try eqStr(
        \\5 4/75/72
        \\  4 2/38/36
        \\    3 1/16/15
        \\      2 1/2/2
        \\        1 B| `1`
        \\        1 `2`
        \\      1 `const a = 10;` |E Rc:2
        \\    1 B| `var not_false = true;` |E Rc:3
        \\  2 2/37/36 Rc:3
        \\    1 B| `const Allocator = std.mem.Allocator;` |E
        \\    1 B| ``
    , try debugStr(idc_if_it_leaks, e2));

    const e2_has_changes, const e2b = try balance(testing_allocator, e2);
    {
        try eq(true, e2_has_changes);
        freeRcNode(testing_allocator, e2);
        try eqStr(
            \\4 4/75/72
            \\  3 2/38/36
            \\    2 1/2/2
            \\      1 B| `1`
            \\      1 `2`
            \\    2 1/36/34
            \\      1 `const a = 10;` |E Rc:2
            \\      1 B| `var not_false = true;` |E Rc:3
            \\  2 2/37/36 Rc:3
            \\    1 B| `const Allocator = std.mem.Allocator;` |E
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, e2b));
    }

    ///////////////////////////// e3

    const e3line, const e3col, const e3 = try insertChars(e2b, testing_allocator, &content_arena, "3", .{ .line = e2line, .col = e2col });
    try list.append(e2b);
    try eqStr(
        \\5 4/76/73
        \\  4 2/39/37
        \\    3 1/3/3
        \\      1 B| `1` Rc:2
        \\      2 0/2/2
        \\        1 `2`
        \\        1 `3`
        \\    2 1/36/34 Rc:2
        \\      1 `const a = 10;` |E Rc:2
        \\      1 B| `var not_false = true;` |E Rc:3
        \\  2 2/37/36 Rc:4
        \\    1 B| `const Allocator = std.mem.Allocator;` |E
        \\    1 B| ``
    , try debugStr(idc_if_it_leaks, e3));

    const e3_has_changes, const e3b = try balance(testing_allocator, e3);
    {
        try eq(true, e3_has_changes);
        freeRcNode(testing_allocator, e3);
        try eqStr(
            \\4 4/76/73
            \\  3 1/3/3
            \\    1 B| `1` Rc:2
            \\    2 0/2/2
            \\      1 `2`
            \\      1 `3`
            \\  3 3/73/70
            \\    2 1/36/34 Rc:2
            \\      1 `const a = 10;` |E Rc:2
            \\      1 B| `var not_false = true;` |E Rc:3
            \\    2 2/37/36 Rc:4
            \\      1 B| `const Allocator = std.mem.Allocator;` |E
            \\      1 B| ``
        , try debugStr(idc_if_it_leaks, e3b));
    }

    ///////////////////////////// e4

    const e4line, const e4col, const e4 = try insertChars(e3b, testing_allocator, &content_arena, "4", .{ .line = e3line, .col = e3col });
    try list.append(e3b);
    try eqStr(
        \\5 4/77/74
        \\  4 1/4/4
        \\    1 B| `1` Rc:3
        \\    3 0/3/3
        \\      1 `2` Rc:2
        \\      2 0/2/2
        \\        1 `3`
        \\        1 `4`
        \\  3 3/73/70 Rc:2
        \\    2 1/36/34 Rc:2
        \\      1 `const a = 10;` |E Rc:2
        \\      1 B| `var not_false = true;` |E Rc:3
        \\    2 2/37/36 Rc:4
        \\      1 B| `const Allocator = std.mem.Allocator;` |E
        \\      1 B| ``
    , try debugStr(idc_if_it_leaks, e4));

    try eq(.{ false, e4 }, try balance(testing_allocator, e4));

    ///////////////////////////// e5

    const e5line, const e5col, const e5 = try insertChars(e4, testing_allocator, &content_arena, "5", .{ .line = e4line, .col = e4col });
    try list.append(e4);
    try eqStr(
        \\6 4/78/75
        \\  5 1/5/5
        \\    1 B| `1` Rc:4
        \\    4 0/4/4
        \\      1 `2` Rc:3
        \\      3 0/3/3
        \\        1 `3` Rc:2
        \\        2 0/2/2
        \\          1 `4`
        \\          1 `5`
        \\  3 3/73/70 Rc:3
        \\    2 1/36/34 Rc:2
        \\      1 `const a = 10;` |E Rc:2
        \\      1 B| `var not_false = true;` |E Rc:3
        \\    2 2/37/36 Rc:4
        \\      1 B| `const Allocator = std.mem.Allocator;` |E
        \\      1 B| ``
    , try debugStr(idc_if_it_leaks, e5));

    const e5_has_changes, const e5b = try balance(testing_allocator, e5);
    {
        try eq(true, e5_has_changes);
        freeRcNode(testing_allocator, e5);
        try eqStr(
            \\5 4/78/75
            \\  4 1/5/5
            \\    3 1/3/3
            \\      1 B| `1` Rc:4
            \\      2 0/2/2
            \\        1 `2` Rc:3
            \\        1 `3` Rc:2
            \\    2 0/2/2
            \\      1 `4`
            \\      1 `5`
            \\  3 3/73/70 Rc:3
            \\    2 1/36/34 Rc:2
            \\      1 `const a = 10;` |E Rc:2
            \\      1 B| `var not_false = true;` |E Rc:3
            \\    2 2/37/36 Rc:4
            \\      1 B| `const Allocator = std.mem.Allocator;` |E
            \\      1 B| ``
        , try debugStr(idc_if_it_leaks, e5b));
    }

    ///////////////////////////// e6

    const e6line, const e6col, const e6 = try insertChars(e5b, testing_allocator, &content_arena, "6", .{ .line = e5line, .col = e5col });
    try list.append(e5b);
    try eqStr(
        \\5 4/79/76
        \\  4 1/6/6
        \\    3 1/3/3 Rc:2
        \\      1 B| `1` Rc:4
        \\      2 0/2/2
        \\        1 `2` Rc:3
        \\        1 `3` Rc:2
        \\    3 0/3/3
        \\      1 `4` Rc:2
        \\      2 0/2/2
        \\        1 `5`
        \\        1 `6`
        \\  3 3/73/70 Rc:4
        \\    2 1/36/34 Rc:2
        \\      1 `const a = 10;` |E Rc:2
        \\      1 B| `var not_false = true;` |E Rc:3
        \\    2 2/37/36 Rc:4
        \\      1 B| `const Allocator = std.mem.Allocator;` |E
        \\      1 B| ``
    , try debugStr(idc_if_it_leaks, e6));

    try eq(.{ false, e6 }, try balance(testing_allocator, e6));

    ///////////////////////////// e7

    const e7line, const e7col, const e7 = try insertChars(e6, testing_allocator, &content_arena, "7", .{ .line = e6line, .col = e6col });
    try list.append(e6);
    try eqStr(
        \\6 4/80/77
        \\  5 1/7/7
        \\    3 1/3/3 Rc:3
        \\      1 B| `1` Rc:4
        \\      2 0/2/2
        \\        1 `2` Rc:3
        \\        1 `3` Rc:2
        \\    4 0/4/4
        \\      1 `4` Rc:3
        \\      3 0/3/3
        \\        1 `5` Rc:2
        \\        2 0/2/2
        \\          1 `6`
        \\          1 `7`
        \\  3 3/73/70 Rc:5
        \\    2 1/36/34 Rc:2
        \\      1 `const a = 10;` |E Rc:2
        \\      1 B| `var not_false = true;` |E Rc:3
        \\    2 2/37/36 Rc:4
        \\      1 B| `const Allocator = std.mem.Allocator;` |E
        \\      1 B| ``
    , try debugStr(idc_if_it_leaks, e7));

    const e7_has_changes, const e7b = try balance(testing_allocator, e7);
    {
        try eq(true, e7_has_changes);
        freeRcNode(testing_allocator, e7);
        try eqStr(
            \\5 4/80/77
            \\  4 1/4/4
            \\    3 1/3/3 Rc:3
            \\      1 B| `1` Rc:4
            \\      2 0/2/2
            \\        1 `2` Rc:3
            \\        1 `3` Rc:2
            \\    1 `4` Rc:3
            \\  4 3/76/73
            \\    3 0/3/3
            \\      1 `5` Rc:2
            \\      2 0/2/2
            \\        1 `6`
            \\        1 `7`
            \\    3 3/73/70 Rc:5
            \\      2 1/36/34 Rc:2
            \\        1 `const a = 10;` |E Rc:2
            \\        1 B| `var not_false = true;` |E Rc:3
            \\      2 2/37/36 Rc:4
            \\        1 B| `const Allocator = std.mem.Allocator;` |E
            \\        1 B| ``
        , try debugStr(idc_if_it_leaks, e7b));
    }

    ///////////////////////////// e8

    const e8line, const e8col, const e8 = try insertChars(e7b, testing_allocator, &content_arena, "8", .{ .line = e7line, .col = e7col });
    try list.append(e7b);
    try eqStr(
        \\6 4/81/78
        \\  4 1/4/4 Rc:2
        \\    3 1/3/3 Rc:3
        \\      1 B| `1` Rc:4
        \\      2 0/2/2
        \\        1 `2` Rc:3
        \\        1 `3` Rc:2
        \\    1 `4` Rc:3
        \\  5 3/77/74
        \\    4 0/4/4
        \\      1 `5` Rc:3
        \\      3 0/3/3
        \\        1 `6` Rc:2
        \\        2 0/2/2
        \\          1 `7`
        \\          1 `8`
        \\    3 3/73/70 Rc:6
        \\      2 1/36/34 Rc:2
        \\        1 `const a = 10;` |E Rc:2
        \\        1 B| `var not_false = true;` |E Rc:3
        \\      2 2/37/36 Rc:4
        \\        1 B| `const Allocator = std.mem.Allocator;` |E
        \\        1 B| ``
    , try debugStr(idc_if_it_leaks, e8));

    try eq(.{ false, e8 }, try balance(testing_allocator, e8));

    ////////////////////////////////////////////////////////// e9

    const e9line, const e9col, const e9 = try insertChars(e8, testing_allocator, &content_arena, "9", .{ .line = e8line, .col = e8col });
    try list.append(e8);

    try eqStr(
        \\7 4/82/79
        \\  4 1/4/4 Rc:3
        \\    3 1/3/3 Rc:3
        \\      1 B| `1` Rc:4
        \\      2 0/2/2
        \\        1 `2` Rc:3
        \\        1 `3` Rc:2
        \\    1 `4` Rc:3
        \\  6 3/78/75
        \\    5 0/5/5
        \\      1 `5` Rc:4
        \\      4 0/4/4
        \\        1 `6` Rc:3
        \\        3 0/3/3
        \\          1 `7` Rc:2
        \\          2 0/2/2
        \\            1 `8`
        \\            1 `9`
        \\    3 3/73/70 Rc:7
        \\      2 1/36/34 Rc:2
        \\        1 `const a = 10;` |E Rc:2
        \\        1 B| `var not_false = true;` |E Rc:3
        \\      2 2/37/36 Rc:4
        \\        1 B| `const Allocator = std.mem.Allocator;` |E
        \\        1 B| ``
    , try debugStr(idc_if_it_leaks, e9));

    const e9_has_changes, const e9b = try balance(testing_allocator, e9);
    // after balance() before freeing list.items
    try eqStr(
        \\7 4/82/79
        \\  4 1/4/4 Rc:3
        \\    3 1/3/3 Rc:3
        \\      1 B| `1` Rc:5
        \\      2 0/2/2
        \\        1 `2` Rc:4
        \\        1 `3` Rc:3
        \\    1 `4` Rc:4
        \\  6 3/78/75
        \\    5 0/5/5
        \\      1 `5` Rc:5
        \\      4 0/4/4
        \\        1 `6` Rc:4
        \\        3 0/3/3
        \\          1 `7` Rc:3
        \\          2 0/2/2 Rc:2
        \\            1 `8`
        \\            1 `9`
        \\    3 3/73/70 Rc:8
        \\      2 1/36/34 Rc:2
        \\        1 `const a = 10;` |E Rc:2
        \\        1 B| `var not_false = true;` |E Rc:3
        \\      2 2/37/36 Rc:4
        \\        1 B| `const Allocator = std.mem.Allocator;` |E
        \\        1 B| ``
    , try debugStr(idc_if_it_leaks, e9));

    {
        try eq(true, e9_has_changes);
        try eqStr(
            \\5 4/82/79
            \\  4 1/7/7
            \\    3 1/4/4
            \\      2 1/2/2
            \\        1 B| `1` Rc:5
            \\        1 `2` Rc:4
            \\      2 0/2/2
            \\        1 `3` Rc:3
            \\        1 `4` Rc:4
            \\    3 0/3/3
            \\      1 `5` Rc:5
            \\      2 0/2/2
            \\        1 `6` Rc:4
            \\        1 `7` Rc:3
            \\  4 3/75/72
            \\    2 0/2/2 Rc:2
            \\      1 `8`
            \\      1 `9`
            \\    3 3/73/70 Rc:8
            \\      2 1/36/34 Rc:2
            \\        1 `const a = 10;` |E Rc:2
            \\        1 B| `var not_false = true;` |E Rc:3
            \\      2 2/37/36 Rc:4
            \\        1 B| `const Allocator = std.mem.Allocator;` |E
            \\        1 B| ``
        , try debugStr(idc_if_it_leaks, e9b));

        { // used to cause memory corruption
            // for (list.items, 0..) |node, i| {
            //     std.debug.print("========= i = {d} ================================\n", .{i});
            //     std.debug.print("node:\n {s}\n", .{try debugStr(idc_if_it_leaks, node)});
            //     freeRcNode(testing_allocator, node);
            // }

            freeRcNodes(testing_allocator, list.items);
            freeRcNode(testing_allocator, e9);
        }

        try eqStr(
            \\5 4/82/79
            \\  4 1/7/7
            \\    3 1/4/4
            \\      2 1/2/2
            \\        1 B| `1`
            \\        1 `2`
            \\      2 0/2/2
            \\        1 `3`
            \\        1 `4`
            \\    3 0/3/3
            \\      1 `5`
            \\      2 0/2/2
            \\        1 `6`
            \\        1 `7`
            \\  4 3/75/72
            \\    2 0/2/2
            \\      1 `8`
            \\      1 `9`
            \\    3 3/73/70
            \\      2 1/36/34
            \\        1 `const a = 10;` |E
            \\        1 B| `var not_false = true;` |E
            \\      2 2/37/36
            \\        1 B| `const Allocator = std.mem.Allocator;` |E
            \\        1 B| ``
        , try debugStr(idc_if_it_leaks, e9b));
    }

    /////////////////////////////

    _ = e9line;
    _ = e9col;

    freeRcNode(testing_allocator, e9b);
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

    // sanity check
    {
        try eqStr(
            \\1 B| `ACD`
        , try debugStr(idc_if_it_leaks, acd));

        try eqStr(
            \\3 1/4/4
            \\  1 B| `A` Rc:2
            \\  2 0/3/3
            \\    1 `B` Rc:2
            \\    1 `CD`
        , try debugStr(idc_if_it_leaks, abcd));

        try eqStr(
            \\4 1/5/5
            \\  1 B| `A` Rc:2
            \\  3 0/4/4
            \\    1 `B` Rc:2
            \\    2 0/3/3
            \\      1 `CD`
            \\      1 `E`
        , try debugStr(idc_if_it_leaks, abcde));
    }

    ///////////////////////////// after rotateLeft

    const abcde_rotated = try rotateLeft(testing_allocator, abcde);
    try eqStr(
        \\3 1/5/5
        \\  2 1/2/2
        \\    1 B| `A` Rc:3
        \\    1 `B` Rc:3
        \\  2 0/3/3 Rc:2
        \\    1 `CD`
        \\    1 `E`
    , try debugStr(idc_if_it_leaks, abcde_rotated));

    // sanity check
    {
        try eqStr(
            \\1 B| `ACD`
        , try debugStr(idc_if_it_leaks, acd));

        try eqStr(
            \\3 1/4/4
            \\  1 B| `A` Rc:3
            \\  2 0/3/3
            \\    1 `B` Rc:3
            \\    1 `CD`
        , try debugStr(idc_if_it_leaks, abcd));

        try eqStr(
            \\4 1/5/5
            \\  1 B| `A` Rc:3
            \\  3 0/4/4
            \\    1 `B` Rc:3
            \\    2 0/3/3 Rc:2
            \\      1 `CD`
            \\      1 `E`
        , try debugStr(idc_if_it_leaks, abcde));
    }

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

    const def = try Node.fromString(testing_allocator, &content_arena, "DEF");
    _, _, const cdef = try insertChars(def, testing_allocator, &content_arena, "C", .{ .line = 0, .col = 0 });
    _, _, const bcdef = try insertChars(cdef, testing_allocator, &content_arena, "B", .{ .line = 0, .col = 0 });
    _, _, const abcdef = try insertChars(bcdef, testing_allocator, &content_arena, "A", .{ .line = 0, .col = 0 });

    // sanity check
    {
        try eqStr(
            \\1 B| `DEF`
        , try debugStr(idc_if_it_leaks, def));

        try eqStr(
            \\2 1/4/4
            \\  1 B| `C`
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, cdef));

        try eqStr(
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `B`
            \\    1 `C` Rc:2
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, bcdef));

        try eqStr(
            \\4 1/6/6
            \\  3 1/3/3
            \\    2 1/2/2
            \\      1 B| `A`
            \\      1 `B`
            \\    1 `C` Rc:2
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, abcdef));
    }

    ///////////////////////////// after rotateRight

    const abcdef_rotated = try rotateRight(testing_allocator, abcdef);
    try eqStr(
        \\3 1/6/6
        \\  2 1/2/2 Rc:2
        \\    1 B| `A`
        \\    1 `B`
        \\  2 0/4/4
        \\    1 `C` Rc:3
        \\    1 `DEF` Rc:4
    , try debugStr(idc_if_it_leaks, abcdef_rotated));

    // sanity check
    {
        try eqStr(
            \\1 B| `DEF`
        , try debugStr(idc_if_it_leaks, def));

        try eqStr(
            \\2 1/4/4
            \\  1 B| `C`
            \\  1 `DEF` Rc:4
        , try debugStr(idc_if_it_leaks, cdef));

        try eqStr(
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `B`
            \\    1 `C` Rc:3
            \\  1 `DEF` Rc:4
        , try debugStr(idc_if_it_leaks, bcdef));

        try eqStr(
            \\4 1/6/6
            \\  3 1/3/3
            \\    2 1/2/2 Rc:2
            \\      1 B| `A`
            \\      1 `B`
            \\    1 `C` Rc:3
            \\  1 `DEF` Rc:4
        , try debugStr(idc_if_it_leaks, abcdef));
    }

    freeRcNodes(testing_allocator, &.{ def, cdef, bcdef, abcdef, abcdef_rotated });
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
            defer if (strong_count.len > 0) a.free(strong_count);
            const content = try std.fmt.allocPrint(a, "{d} {d}/{d}/{d}{s}", .{
                branch.weights.depth,
                branch.weights.bols,
                branch.weights.len,
                branch.weights.noc,
                strong_count,
            });
            defer a.free(content);
            try result.appendSlice(content);
            try _buildDebugStr(a, branch.left, result, indent_level + 2);
            try _buildDebugStr(a, branch.right, result, indent_level + 2);
        },
        .leaf => |leaf| {
            const bol = if (leaf.bol) "B| " else "";
            const eol = if (leaf.eol) " |E" else "";
            const strong_count = if (node.strongCount() == 1) "" else try std.fmt.allocPrint(a, " Rc:{d}", .{node.strongCount()});
            defer if (strong_count.len > 0) a.free(strong_count);
            const leaf_content = if (leaf.buf.len > 0) leaf.buf else "";
            const content = try std.fmt.allocPrint(a, "1 {s}`{s}`{s}{s}", .{ bol, leaf_content, eol, strong_count });
            defer a.free(content);
            try result.appendSlice(content);
        },
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// getPositionFromByteOffset

pub fn getPositionFromByteOffset(self: RcNode, byte_offset: usize) !struct { usize, usize } {
    const GetPositionCtx = struct {
        target_byte_offset: usize,
        current_byte_offset: usize = 0,

        line: usize = 0,
        col: usize = 0,

        fn walk(cx: *@This(), node: RcNode) WalkError!WalkResult {
            switch (node.value.*) {
                .branch => |*branch| {
                    var left = WalkResult.keep_walking;
                    const left_branch_contains_target = branch.left.value.weights().len + cx.target_byte_offset >= cx.target_byte_offset;
                    if (left_branch_contains_target) {
                        left = try cx.walk(branch.left);
                    } else {
                        cx.current_byte_offset += branch.left.value.weights().len;
                        cx.line += branch.left.value.weights().bols;
                    }
                    if (left.keep_walking == false) return WalkResult.stop;

                    const right = try cx.walk(branch.right);
                    return try WalkResult.merge(branch, idc_if_it_leaks, left, right);
                },
                .leaf => |leaf| return cx.walker(&leaf),
            }
        }

        fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
            if (leaf.bol) cx.col = 0;

            const leaf_contains_target = leaf.buf.len + cx.current_byte_offset >= cx.target_byte_offset;
            if (leaf_contains_target) {
                var iter = code_point.Iterator{ .bytes = leaf.buf };
                while (iter.next()) |cp| {
                    if (cx.current_byte_offset >= cx.target_byte_offset) break;
                    cx.current_byte_offset += cp.len;
                    cx.col += 1;
                }
                return WalkResult.stop;
            }

            cx.current_byte_offset += leaf.weights().len;
            cx.col += leaf.noc;
            if (leaf.eol) cx.line += 1;
            return WalkResult.keep_walking;
        }
    };

    var ctx = GetPositionCtx{ .target_byte_offset = byte_offset };
    _ = try ctx.walk(self);
    return .{ ctx.line, ctx.col };
}

test getPositionFromByteOffset {
    const a = idc_if_it_leaks;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    {
        const root = try Node.fromString(a, &arena, "123456789");
        try eq(.{ 0, 0 }, getPositionFromByteOffset(root, 0));
        try eq(.{ 0, 1 }, getPositionFromByteOffset(root, 1));
        try eq(.{ 0, 5 }, getPositionFromByteOffset(root, 5));
    }
    {
        const source = "one\ntwo\nthree\nfour";
        const root = try Node.fromString(a, &arena, source);

        try eq(.{ 0, 0 }, getPositionFromByteOffset(root, 0));
        try eq(0, getByteOffsetOfPosition(root, 0, 0));

        try eq(.{ 0, 3 }, getPositionFromByteOffset(root, 3));
        try eq(3, getByteOffsetOfPosition(root, 0, 3));

        try eq(.{ 1, 0 }, getPositionFromByteOffset(root, 4));
        try eq(4, getByteOffsetOfPosition(root, 1, 0));

        try eq(.{ 1, 1 }, getPositionFromByteOffset(root, 5));
        try eq(5, getByteOffsetOfPosition(root, 1, 1));

        try eq(.{ 2, 0 }, getPositionFromByteOffset(root, 8));
        try eq(8, getByteOffsetOfPosition(root, 2, 0));

        try eq(.{ 2, 5 }, getPositionFromByteOffset(root, 13));
        try eq(13, getByteOffsetOfPosition(root, 2, 5));

        try eq(.{ 3, 0 }, getPositionFromByteOffset(root, 14));
        try eq(14, getByteOffsetOfPosition(root, 3, 0));
    }
    {
        const reverse_input_sequence = "4444\n333\n22\n1";
        const root = try __inputCharsOneAfterAnotherAt0Position(a, &arena, reverse_input_sequence);
        const root_debug_str =
            \\13 4/13/10
            \\  12 4/12/9
            \\    11 4/11/8
            \\      10 4/10/7
            \\        9 3/9/6
            \\          8 3/8/6
            \\            7 3/7/5
            \\              6 3/6/4
            \\                5 2/5/3
            \\                  4 2/4/3
            \\                    3 2/3/2
            \\                      2 1/2/1
            \\                        1 B| `1`
            \\                        1 `` |E
            \\                      1 B| `2` Rc:2
            \\                    1 `2` Rc:3
            \\                  1 `` |E Rc:4
            \\                1 B| `3` Rc:5
            \\              1 `3` Rc:6
            \\            1 `3` Rc:7
            \\          1 `` |E Rc:8
            \\        1 B| `4` Rc:9
            \\      1 `4` Rc:10
            \\    1 `4` Rc:11
            \\  1 `4` Rc:12
        ;
        try eqStr(root_debug_str, try debugStr(idc_if_it_leaks, root));

        try eq(.{ 0, 0 }, getPositionFromByteOffset(root, 0));
        try eq(.{ 0, 1 }, getPositionFromByteOffset(root, 1));
        try eq(0, getByteOffsetOfPosition(root, 0, 0));
        try eq(1, getByteOffsetOfPosition(root, 0, 1));

        try eq(.{ 1, 0 }, getPositionFromByteOffset(root, 2));
        try eq(.{ 1, 1 }, getPositionFromByteOffset(root, 3));
        try eq(.{ 1, 2 }, getPositionFromByteOffset(root, 4));
        try eq(2, getByteOffsetOfPosition(root, 1, 0));
        try eq(3, getByteOffsetOfPosition(root, 1, 1));
        try eq(4, getByteOffsetOfPosition(root, 1, 2));

        try eq(.{ 2, 0 }, getPositionFromByteOffset(root, 5));
        try eq(.{ 2, 1 }, getPositionFromByteOffset(root, 6));
        try eq(.{ 2, 2 }, getPositionFromByteOffset(root, 7));
        try eq(.{ 2, 3 }, getPositionFromByteOffset(root, 8));
        try eq(5, getByteOffsetOfPosition(root, 2, 0));
        try eq(6, getByteOffsetOfPosition(root, 2, 1));
        try eq(7, getByteOffsetOfPosition(root, 2, 2));
        try eq(8, getByteOffsetOfPosition(root, 2, 3));
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// getByteOffsetOfPosition

const GetByteOffsetOfPositionError = error{ OutOfMemory, LineOutOfBounds, ColOutOfBounds };
pub fn getByteOffsetOfPosition(self: RcNode, line: usize, col: usize) GetByteOffsetOfPositionError!usize {
    const GetByteOffsetCtx = struct {
        target_line: usize,
        target_col: usize,

        byte_offset: usize = 0,
        current_line: usize = 0,
        current_col: usize = 0,
        should_stop: bool = false,
        encountered_bol: bool = false,

        fn walk(cx: *@This(), node: RcNode) WalkError!WalkResult {
            if (cx.should_stop) return WalkResult.stop;

            switch (node.value.*) {
                .branch => |*branch| {
                    const left_bols_end = cx.current_line + branch.left.value.weights().bols;

                    var left = WalkResult.keep_walking;
                    if (cx.current_line == cx.target_line or cx.target_line < left_bols_end) {
                        left = try cx.walk(branch.left);
                    }

                    if (cx.current_line < cx.target_line) {
                        cx.byte_offset += branch.left.value.weights().len;
                    }

                    cx.current_line = left_bols_end;

                    const right = try cx.walk(branch.right);
                    return try WalkResult.merge(branch, idc_if_it_leaks, left, right);
                },
                .leaf => |leaf| return cx.walker(&leaf),
            }
        }

        fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
            if (!cx.encountered_bol and !leaf.bol) {
                cx.byte_offset += leaf.weights().len;
                return WalkResult.keep_walking;
            }

            if (leaf.bol) cx.encountered_bol = true;

            if (cx.encountered_bol and cx.target_col == 0) {
                cx.should_stop = true;
                return WalkResult.stop;
            }

            const sum = cx.current_col + leaf.noc;
            if (sum <= cx.target_col) {
                cx.current_col += leaf.noc;
                cx.byte_offset += leaf.buf.len;
            }
            if (sum > cx.target_col) {
                var iter = code_point.Iterator{ .bytes = leaf.buf };
                while (iter.next()) |cp| {
                    cx.current_col += 1;
                    cx.byte_offset += cp.len;
                    if (cx.current_col >= cx.target_col) break;
                }
            }
            if (cx.encountered_bol and (leaf.eol or sum >= cx.target_col)) {
                cx.should_stop = true;
                return WalkResult.stop;
            }

            if (leaf.eol) cx.byte_offset += 1;
            return WalkResult.keep_walking;
        }
    };

    if (line > self.value.weights().bols) return error.LineOutOfBounds;
    var ctx = GetByteOffsetCtx{ .target_line = line, .target_col = col };
    _ = try ctx.walk(self);
    if (ctx.current_col < col) return error.ColOutOfBounds;
    return ctx.byte_offset;
}

test getByteOffsetOfPosition {
    const a = idc_if_it_leaks;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    {
        const root = try Node.fromString(a, &arena, "Hello World!");
        try shouldErr(error.LineOutOfBounds, getByteOffsetOfPosition(root, 3, 0));
        try shouldErr(error.LineOutOfBounds, getByteOffsetOfPosition(root, 2, 0));
        try eq(0, getByteOffsetOfPosition(root, 0, 0));
        try eq(1, getByteOffsetOfPosition(root, 0, 1));
        try eq(2, getByteOffsetOfPosition(root, 0, 2));
        try eq(11, getByteOffsetOfPosition(root, 0, 11));
        try eq(12, getByteOffsetOfPosition(root, 0, 12));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 13));
    }
    {
        const source = "one\ntwo\nthree\nfour";
        const root = try Node.fromString(a, &arena, source);

        try eqStr("o", source[0..1]);
        try eq(0, getByteOffsetOfPosition(root, 0, 0));
        try eqStr("e", source[2..3]);
        try eq(2, getByteOffsetOfPosition(root, 0, 2));
        try eqStr("\n", source[3..4]);
        try eq(3, getByteOffsetOfPosition(root, 0, 3));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 4));

        try eqStr("t", source[4..5]);
        try eq(4, getByteOffsetOfPosition(root, 1, 0));
        try eqStr("o", source[6..7]);
        try eq(6, getByteOffsetOfPosition(root, 1, 2));
        try eqStr("\n", source[7..8]);
        try eq(7, getByteOffsetOfPosition(root, 1, 3));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 1, 4));

        try eqStr("t", source[8..9]);
        try eq(8, getByteOffsetOfPosition(root, 2, 0));
        try eqStr("e", source[12..13]);
        try eq(12, getByteOffsetOfPosition(root, 2, 4));
        try eqStr("\n", source[13..14]);
        try eq(13, getByteOffsetOfPosition(root, 2, 5));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 2, 6));

        try eqStr("f", source[14..15]);
        try eq(14, getByteOffsetOfPosition(root, 3, 0));
        try eqStr("r", source[17..18]);
        try eq(17, getByteOffsetOfPosition(root, 3, 3));
        // no eol on this line
        try eq(18, source.len);
        try eq(18, getByteOffsetOfPosition(root, 3, 4));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 3, 5));
    }
    {
        const one = try Leaf.new(a, "one", true, false);
        const two = try Leaf.new(a, "_two", false, false);
        const three = try Leaf.new(a, "_three", false, true);
        const four = try Leaf.new(a, "four", true, true);
        const two_three = try Node.new(a, two, three);
        const one_two_three = try Node.new(a, one, two_three);
        {
            const root = try Node.new(a, one_two_three, four);
            const txt = "one_two_three\nfour";

            try eqStr("o", txt[0..1]);
            try eq(0, getByteOffsetOfPosition(root, 0, 0));
            try eqStr("e", txt[12..13]);
            try eq(13, getByteOffsetOfPosition(root, 0, 13));
            try eqStr("\n", txt[13..14]);
            try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 14));

            try eqStr("f", txt[14..15]);
            try eq(14, getByteOffsetOfPosition(root, 1, 0));
            try eqStr("r", txt[17..18]);
            try eq(18, getByteOffsetOfPosition(root, 1, 4));
            try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 1, 5));
        }
    }

    // make sure that getByteOffsetOfPosition() works properly with ugly tree structure,
    // where bol is in one leaf, and eol is in another leaf in a different branch.
    {
        const eol_hello = try Node.new(a, try Leaf.new(a, "", false, true), try Leaf.new(a, "    \\\\hello", true, true));
        const const_hello = try Node.new(a, try Leaf.new(a, "const str =", true, false), eol_hello);
        const semicolon = try Node.new(a, try Leaf.new(a, "", true, false), try Leaf.new(a, ";", false, false));
        const world_semicolon = try Node.new(a, try Leaf.new(a, "    \\\\world", true, true), semicolon);
        const root = try Node.new(a, const_hello, world_semicolon);
        const root_debug_str =
            \\4 4/37/34
            \\  3 2/24/22
            \\    1 B| `const str =`
            \\    2 1/13/11
            \\      1 `` |E
            \\      1 B| `    \\hello` |E
            \\  3 2/13/12
            \\    1 B| `    \\world` |E
            \\    2 1/1/1
            \\      1 B| ``
            \\      1 `;`
        ;
        try eqStr(root_debug_str, try debugStr(idc_if_it_leaks, root));
        try eq(11, getByteOffsetOfPosition(root, 0, 11));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 12));
        try eq(23, getByteOffsetOfPosition(root, 1, 11));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 1, 12));
        try eq(35, getByteOffsetOfPosition(root, 2, 11));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 2, 12));
        try eq(36, getByteOffsetOfPosition(root, 3, 0));
        try eq(37, getByteOffsetOfPosition(root, 3, 1));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 3, 2));
    }

    {
        const source = "1\n22\n333\n4444";
        const nodes = try insertCharOneAfterAnother(idc_if_it_leaks, &arena, source);
        const root = nodes.items[nodes.items.len - 1];
        const root_debug_str =
            \\13 4/13/10
            \\  1 B| `1` Rc:12
            \\  12 3/12/9
            \\    1 `` |E Rc:12
            \\    11 3/11/9
            \\      1 B| `2` Rc:10
            \\      10 2/10/8
            \\        1 `2` Rc:9
            \\        9 2/9/7
            \\          1 `` |E Rc:9
            \\          8 2/8/7
            \\            1 B| `3` Rc:7
            \\            7 1/7/6
            \\              1 `3` Rc:6
            \\              6 1/6/5
            \\                1 `3` Rc:5
            \\                5 1/5/4
            \\                  1 `` |E Rc:5
            \\                  4 1/4/4
            \\                    1 B| `4` Rc:3
            \\                    3 0/3/3
            \\                      1 `4` Rc:2
            \\                      2 0/2/2
            \\                        1 `4`
            \\                        1 `4`
        ;
        try eqStr(root_debug_str, try debugStr(idc_if_it_leaks, root));
        try eq(0, getByteOffsetOfPosition(root, 0, 0));
        try eq(1, getByteOffsetOfPosition(root, 0, 1));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 2));
        try eq(2, getByteOffsetOfPosition(root, 1, 0));
        try eq(3, getByteOffsetOfPosition(root, 1, 1));
        try eq(4, getByteOffsetOfPosition(root, 1, 2));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 1, 3));
        try eq(5, getByteOffsetOfPosition(root, 2, 0));
        try eq(6, getByteOffsetOfPosition(root, 2, 1));
        try eq(7, getByteOffsetOfPosition(root, 2, 2));
        try eq(8, getByteOffsetOfPosition(root, 2, 3));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 2, 4));
    }
    {
        const reverse_input_sequence = "4444\n333\n22\n1";
        const root = try __inputCharsOneAfterAnotherAt0Position(a, &arena, reverse_input_sequence);
        const root_debug_str =
            \\13 4/13/10
            \\  12 4/12/9
            \\    11 4/11/8
            \\      10 4/10/7
            \\        9 3/9/6
            \\          8 3/8/6
            \\            7 3/7/5
            \\              6 3/6/4
            \\                5 2/5/3
            \\                  4 2/4/3
            \\                    3 2/3/2
            \\                      2 1/2/1
            \\                        1 B| `1`
            \\                        1 `` |E
            \\                      1 B| `2` Rc:2
            \\                    1 `2` Rc:3
            \\                  1 `` |E Rc:4
            \\                1 B| `3` Rc:5
            \\              1 `3` Rc:6
            \\            1 `3` Rc:7
            \\          1 `` |E Rc:8
            \\        1 B| `4` Rc:9
            \\      1 `4` Rc:10
            \\    1 `4` Rc:11
            \\  1 `4` Rc:12
        ;
        try eqStr(root_debug_str, try debugStr(idc_if_it_leaks, root));
        try eq(0, getByteOffsetOfPosition(root, 0, 0));
        try eq(1, getByteOffsetOfPosition(root, 0, 1));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 0, 2));
        try eq(2, getByteOffsetOfPosition(root, 1, 0));
        try eq(3, getByteOffsetOfPosition(root, 1, 1));
        try eq(4, getByteOffsetOfPosition(root, 1, 2));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 1, 3));
        try eq(5, getByteOffsetOfPosition(root, 2, 0));
        try eq(6, getByteOffsetOfPosition(root, 2, 1));
        try eq(7, getByteOffsetOfPosition(root, 2, 2));
        try eq(8, getByteOffsetOfPosition(root, 2, 3));
        try shouldErr(error.ColOutOfBounds, getByteOffsetOfPosition(root, 2, 4));
    }
}

fn __inputCharsOneAfterAnotherAt0Position(a: Allocator, arena: *ArenaAllocator, chars: []const u8) !RcNode {
    var root = try Node.fromString(a, arena, "");
    for (0..chars.len) |i| _, _, root = try insertChars(root, a, arena, chars[i .. i + 1], .{ .line = 0, .col = 0 });
    return root;
}

////////////////////////////////////////////////////////////////////////////////////////////// GetRange

const GetRangeCtx = struct {
    list: *ArrayList(u8),

    col: usize,
    out_of_memory: bool = false,
    out_of_bounds: bool = false,

    last_line: bool = false,
    last_line_col: ?usize = null,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));

        if (leaf.noc == ctx.col and leaf.eol and ctx.last_line_col == null) {
            ctx.list.append('\n') catch {
                ctx.out_of_memory = true;
                return WalkResult.stop;
            };
            ctx.col = 0;
            return WalkResult.stop;
        }

        if (!leaf.eol and leaf.noc < ctx.col) {
            ctx.col -= leaf.noc;
            if (ctx.last_line_col) |*llc| llc.* -|= leaf.noc;
            return WalkResult.keep_walking;
        }
        if (ctx.out_of_memory) return WalkResult.stop;

        var iter = code_point.Iterator{ .bytes = leaf.buf };
        while (iter.next()) |cp| {
            if (ctx.last_line_col) |limit| if (iter.i >= limit + 1) break;
            if (iter.i - 1 >= ctx.col) {
                ctx.list.appendSlice(leaf.buf[cp.offset .. cp.offset + cp.len]) catch {
                    ctx.out_of_memory = true;
                    return WalkResult.stop;
                };
            }
        }

        ctx.col -|= leaf.noc;
        if (ctx.last_line_col) |*llc| llc.* -|= leaf.noc;
        if (leaf.eol and ctx.last_line_col == null) {
            ctx.list.append('\n') catch {
                ctx.out_of_memory = true;
                return WalkResult.stop;
            };
        }

        if (leaf.eol) {
            if (ctx.col > 0) ctx.out_of_bounds = true;
            return WalkResult.stop;
        }
        return WalkResult.keep_walking;
    }
};

pub fn getRange(node: RcNode, start: CursorPoint, end: ?CursorPoint, buf: []u8) []const u8 {
    const num_of_lines = node.value.weights().bols;
    if (start.line > num_of_lines -| 1) return "";

    var fba = std.heap.FixedBufferAllocator.init(buf);
    var list = ArrayList(u8).initCapacity(fba.allocator(), buf.len) catch unreachable;

    var ctx: GetRangeCtx = .{ .col = start.col, .list = &list };
    const end_range = if (end == null) num_of_lines else end.?.line + 1;

    for (start.line..end_range) |i| {
        if (i == end_range -| 1) {
            ctx.last_line = true;
            if (end) |e| ctx.last_line_col = e.col;
        }
        const result = walkFromLineBegin(idc_if_it_leaks, node, i, GetRangeCtx.walker, &ctx) catch unreachable;
        if (!result.found or ctx.out_of_bounds) return "";
        if (ctx.out_of_memory) break;
    }
    return list.toOwnedSlice() catch unreachable;
}

test "getRange no end" {
    try testGetRangeNoEnd("hello\nworld", "hello\nworld", .{ .line = 0, .col = 0 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "ello\nworld", .{ .line = 0, .col = 1 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "world", .{ .line = 1, .col = 0 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "orld", .{ .line = 1, .col = 1 }, 1024);

    try testGetRangeNoEnd("hello\nworld", "hell", .{ .line = 0, .col = 0 }, 4);
    try testGetRangeNoEnd("hello\nworld", "ello", .{ .line = 0, .col = 1 }, 4);
    try testGetRangeNoEnd("hello\nworld", "llo\n", .{ .line = 0, .col = 2 }, 4);

    try testGetRangeNoEnd("hello\nworld", "worl", .{ .line = 1, .col = 0 }, 4);
    try testGetRangeNoEnd("hello\nworld", "orld", .{ .line = 1, .col = 1 }, 4);
    try testGetRangeNoEnd("hello\nworld", "rld", .{ .line = 1, .col = 2 }, 4);
    try testGetRangeNoEnd("hello\nworld", "ld", .{ .line = 1, .col = 3 }, 4);

    {
        const source =
            \\const a = 10;
            \\const b = 20;
            \\
            \\const c = 50;
        ;
        try testGetRangeNoEnd(source,
            \\const a = 10;
            \\const b = 20;
            \\
            \\const c = 50;
        , .{ .line = 0, .col = 0 }, 1024);
    }

    try testGetRangeNoEnd("const a = 10;//;", "//;", .{ .line = 0, .col = 13 }, 1024);
    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        var buf: [1024]u8 = undefined;

        const root = try Node.fromString(idc_if_it_leaks, &content_arena, "const a = 10;");
        _, _, const e1 = try insertChars(root, idc_if_it_leaks, &content_arena, ";", .{ .line = 0, .col = 12 });
        _, _, const e2 = try insertChars(e1, idc_if_it_leaks, &content_arena, "/", .{ .line = 0, .col = 13 });
        _, _, const e3 = try insertChars(e2, idc_if_it_leaks, &content_arena, "/", .{ .line = 0, .col = 14 });

        try eqStr("const a = 10;//;", try e3.value.toString(idc_if_it_leaks, .lf));
        try eqStr("//;", getRange(e3, .{ .line = 0, .col = 13 }, null, &buf));
    }

    // out of bounds
    try testGetRangeNoEnd("hello\nworld", "\nworld", .{ .line = 0, .col = 5 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "", .{ .line = 0, .col = 6 }, 1024);

    try testGetRangeNoEnd("hello\nworld", "", .{ .line = 1, .col = 5 }, 1024);
    try testGetRangeNoEnd("hello\nworld\nwide", "\nwide", .{ .line = 1, .col = 5 }, 1024);

    try testGetRangeNoEnd("hello\nworld", "", .{ .line = 1, .col = 6 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "", .{ .line = 2, .col = 0 }, 1024);
    try testGetRangeNoEnd("hello\nworld", "", .{ .line = 100, .col = 0 }, 1024);
}

test "getRange() with end point" {
    try testGetRange("hello\nworld", "hello", .{ .line = 0, .col = 0 }, .{ .line = 0, .col = 5 }, 1024);
    try testGetRange("hello\nworld", "hello\n", .{ .line = 0, .col = 0 }, .{ .line = 1, .col = 0 }, 1024);
    try testGetRange("hello\nworld", "hello\nworld", .{ .line = 0, .col = 0 }, .{ .line = 1, .col = 5 }, 1024);
    try testGetRange("hello\nworld", "wo", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 2 }, 1024);

    try testGetRange("const a = 10;", "const", .{ .line = 0, .col = 0 }, .{ .line = 0, .col = 5 }, 1024);

    try testGetRange("hello\nworld\nand\nvenus", "world\nand", .{ .line = 1, .col = 0 }, .{ .line = 2, .col = 3 }, 1024);
    try testGetRange("hello\nworld\nand\nvenus", "world\nand\n", .{ .line = 1, .col = 0 }, .{ .line = 3, .col = 0 }, 1024);

    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        var buf: [1024]u8 = undefined;

        const root = try Node.fromString(idc_if_it_leaks, &content_arena, "const num = 10;");
        _, _, const e1 = try insertChars(root, idc_if_it_leaks, &content_arena, "X", .{ .line = 0, .col = 6 });

        try eqStr("const Xnum = 10;", try e1.value.toString(idc_if_it_leaks, .lf));
        try eqStr("Xnum", getRange(e1, .{ .line = 0, .col = 6 }, .{ .line = 0, .col = 10 }, &buf));
    }

    // end col out of bounds
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 6 }, 1024);
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 8 }, 1024);
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 1000 }, 1024);
}

fn testGetRange(source: []const u8, expected_str: []const u8, start: CursorPoint, end: ?CursorPoint, comptime buf_size: usize) !void {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();
    var buf: [buf_size]u8 = undefined;
    const root = try Node.fromString(testing_allocator, &content_arena, source);
    defer freeRcNode(testing_allocator, root);
    const result = getRange(root, start, end, &buf);
    try eqStr(expected_str, result);
}

fn testGetRangeNoEnd(source: []const u8, expected_str: []const u8, start: CursorPoint, comptime buf_size: usize) !void {
    try testGetRange(source, expected_str, start, null, buf_size);
}

////////////////////////////////////////////////////////////////////////////////////////////// getLineAlloc

const GetLineAllocCtx = struct {
    list: ArrayList(u8),

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        try ctx.list.appendSlice(leaf.buf);
        if (leaf.eol) return WalkResult.stop;
        return WalkResult.keep_walking;
    }
};

pub fn getLineAlloc(a: Allocator, node: RcNode, line: usize, capacity: usize) ![]const u8 {
    var ctx: GetLineAllocCtx = .{ .list = try ArrayList(u8).initCapacity(a, capacity) };
    errdefer ctx.list.deinit();
    const result = try walkFromLineBegin(a, node, line, GetLineAllocCtx.walker, &ctx);
    if (!result.found) return error.NotFound;
    return try ctx.list.toOwnedSlice();
}

test getLineAlloc {
    var content_arena = std.heap.ArenaAllocator.init(idc_if_it_leaks);
    const root = try Node.fromString(idc_if_it_leaks, &content_arena, "hello\nworld");
    try eqStr("hello", try getLineAlloc(idc_if_it_leaks, root, 0, 1024));
    try eqStr("world", try getLineAlloc(idc_if_it_leaks, root, 1, 1024));
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Colnr of first non space character in line

const GetColnrOfFirstNonSpaceCharCtx = struct {
    result: usize = 0,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));

        var iter = code_point.Iterator{ .bytes = leaf.buf };
        var i: usize = 0;
        defer ctx.result += i;

        while (iter.next()) |cp| {
            defer i += 1;
            switch (cp.code) {
                ' ', '\t' => continue,
                else => return WalkResult.stop,
            }
        }

        if (leaf.eol) return WalkResult.stop;
        return WalkResult.keep_walking;
    }
};

pub fn getColnrOfFirstNonSpaceCharInLine(a: Allocator, node: RcNode, line: usize) usize {
    var ctx: GetColnrOfFirstNonSpaceCharCtx = .{};
    errdefer ctx.list.deinit();
    _ = walkFromLineBegin(a, node, line, GetColnrOfFirstNonSpaceCharCtx.walker, &ctx) catch unreachable;
    return ctx.result -| 1;
}

////////////////////////////////////////////////////////////////////////////////////////////// Get Num of Chars in Line

const GetNumOfCharsInLineCtx = struct {
    result: usize = 0,

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        ctx.result += leaf.noc;
        if (leaf.eol) return WalkResult.stop;
        return WalkResult.keep_walking;
    }
};

pub fn getNumOfCharsInLine(node: RcNode, line: usize) usize {
    var ctx: GetNumOfCharsInLineCtx = .{};
    _ = walkFromLineBegin(std.heap.page_allocator, node, line, GetNumOfCharsInLineCtx.walker, &ctx) catch unreachable;
    return ctx.result;
}

test getNumOfCharsInLine {
    var content_arena = std.heap.ArenaAllocator.init(idc_if_it_leaks);
    const root = try Node.fromString(idc_if_it_leaks, &content_arena, "hello\nsuper nova");
    try eq(5, getNumOfCharsInLine(root, 0));
    try eq(10, getNumOfCharsInLine(root, 1));
}

////////////////////////////////////////////////////////////////////////////////////////////// walkLineCol

fn walkLineCol(a: Allocator, node: RcNode, line: usize, col: usize, f: F, dc: DC, ctx: *anyopaque) WalkError!WalkResult {
    switch (node.value.*) {
        .branch => |*branch| {
            // found target line
            if (line == 0) {
                const left_nocs = branch.left.value.weights().noc;
                if (col >= left_nocs) {
                    dc(ctx, left_nocs);
                    const right = try walkLineCol(a, branch.right, line, col - left_nocs, f, dc, ctx);
                    return goRight(a, branch, right);
                }
                return goLeftRight(a, branch, line, col, f, dc, ctx);
            }

            // finding target line
            const left_bols = branch.left.value.weights().bols;
            if (line >= left_bols) {
                const right = try walkLineCol(a, branch.right, line - left_bols, col, f, dc, ctx);
                return goRight(a, branch, right);
            }
            return goLeftRight(a, branch, line, col, f, dc, ctx);
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

fn goRight(a: Allocator, branch: *Branch, right: WalkResult) !WalkResult {
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

fn goLeftRight(a: Allocator, branch: *Branch, line: usize, col: usize, f: F, dc: DC, ctx: *anyopaque) !WalkResult {
    const left = try walkLineCol(a, branch.left, line, col, f, dc, ctx);
    const right = if (left.found and left.keep_walking) try walk(a, branch.right, f, ctx) else WalkResult{};
    return WalkResult.merge(branch, a, left, right);
}

/////////////////////////////

const TryOutWalkLineColCtx = struct {
    col: usize,
    list: *ArrayList(u8),

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        try ctx.list.appendSlice(leaf.buf);
        if (leaf.eol) return WalkResult.stop;
        return WalkResult.keep_walking;
    }

    fn walkerCol(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        defer ctx.col -|= leaf.noc;

        var offset: usize = 0;
        var iter = code_point.Iterator{ .bytes = leaf.buf };
        while (iter.next()) |cp| {
            if (iter.i - 1 < ctx.col) {
                offset = cp.offset + cp.len;
                continue;
            }
            break;
        }
        try ctx.list.appendSlice(leaf.buf[offset..]);

        if (leaf.eol) return WalkResult.stop;
        return WalkResult.keep_walking;
    }

    fn decrementCol(ctx_: *anyopaque, decrement_col_by: usize) void {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        assert(ctx.col >= decrement_col_by);
        ctx.col -|= decrement_col_by;
    }
};

pub fn tryOutWalkLineCol(a: Allocator, node: RcNode, use_col: bool, line: usize, col: usize) []const u8 {
    var list = ArrayList(u8).initCapacity(a, 1024) catch unreachable;
    var ctx: TryOutWalkLineColCtx = .{ .list = &list, .col = col };
    if (!use_col)
        _ = walkLineCol(a, node, line, col, TryOutWalkLineColCtx.walker, TryOutWalkLineColCtx.decrementCol, &ctx) catch unreachable
    else
        _ = walkLineCol(a, node, line, col, TryOutWalkLineColCtx.walkerCol, TryOutWalkLineColCtx.decrementCol, &ctx) catch unreachable;
    return list.toOwnedSlice() catch unreachable;
}

test tryOutWalkLineCol {
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const root = try Node.fromString(a, &arena, "hello\nfrom\nthe\nother\nside");
        _, _, const e1 = try insertChars(root, a, &arena, "_", .{ .line = 0, .col = 5 });
        _, _, const e2 = try insertChars(e1, a, &arena, "v", .{ .line = 0, .col = 6 });
        _, _, const e3 = try insertChars(e2, a, &arena, "e", .{ .line = 0, .col = 7 });
        _, _, const e4 = try insertChars(e3, a, &arena, "n", .{ .line = 0, .col = 8 });
        _, _, const e5 = try insertChars(e4, a, &arena, "u", .{ .line = 0, .col = 9 });
        _, _, const e6 = try insertChars(e5, a, &arena, "s", .{ .line = 0, .col = 10 });

        try eqStr(
            \\9 5/31/27
            \\  8 2/17/15
            \\    7 1/12/11
            \\      1 B| `hello` Rc:6
            \\      6 0/7/6
            \\        1 `_` Rc:5
            \\        5 0/6/5
            \\          1 `v` Rc:4
            \\          4 0/5/4
            \\            1 `e` Rc:3
            \\            3 0/4/3
            \\              1 `n` Rc:2
            \\              2 0/3/2
            \\                1 `u`
            \\                1 `s` |E
            \\    1 B| `from` |E Rc:7
            \\  3 3/14/12 Rc:7
            \\    1 B| `the` |E
            \\    2 2/10/9
            \\      1 B| `other` |E
            \\      1 B| `side`
        , try debugStr(a, e6));

        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 0, 0));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 0, 1));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 0, 2));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 0, 3));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 0, 4));
        try eqStr("_venus", tryOutWalkLineCol(a, e6, false, 0, 5));
        try eqStr("venus", tryOutWalkLineCol(a, e6, false, 0, 6));
        try eqStr("enus", tryOutWalkLineCol(a, e6, false, 0, 7));
        try eqStr("nus", tryOutWalkLineCol(a, e6, false, 0, 8));
        try eqStr("us", tryOutWalkLineCol(a, e6, false, 0, 9));
        try eqStr("s", tryOutWalkLineCol(a, e6, false, 0, 10));

        try eqStr("from", tryOutWalkLineCol(a, e6, false, 1, 0));
        try eqStr("the", tryOutWalkLineCol(a, e6, false, 2, 0));
        try eqStr("other", tryOutWalkLineCol(a, e6, false, 3, 0));
        try eqStr("side", tryOutWalkLineCol(a, e6, false, 4, 0));
    }

    {
        const root = try Node.fromString(a, &arena, "from\nhello\nthe\nother\nside");
        _, _, const e1 = try insertChars(root, a, &arena, "_", .{ .line = 1, .col = 5 });
        _, _, const e2 = try insertChars(e1, a, &arena, "v", .{ .line = 1, .col = 6 });
        _, _, const e3 = try insertChars(e2, a, &arena, "e", .{ .line = 1, .col = 7 });
        _, _, const e4 = try insertChars(e3, a, &arena, "n", .{ .line = 1, .col = 8 });
        _, _, const e5 = try insertChars(e4, a, &arena, "u", .{ .line = 1, .col = 9 });
        _, _, const e6 = try insertChars(e5, a, &arena, "s", .{ .line = 1, .col = 10 });

        try eqStr(
            \\9 5/31/27
            \\  8 2/17/15
            \\    1 B| `from` |E Rc:7
            \\    7 1/12/11
            \\      1 B| `hello` Rc:6
            \\      6 0/7/6
            \\        1 `_` Rc:5
            \\        5 0/6/5
            \\          1 `v` Rc:4
            \\          4 0/5/4
            \\            1 `e` Rc:3
            \\            3 0/4/3
            \\              1 `n` Rc:2
            \\              2 0/3/2
            \\                1 `u`
            \\                1 `s` |E
            \\  3 3/14/12 Rc:7
            \\    1 B| `the` |E
            \\    2 2/10/9
            \\      1 B| `other` |E
            \\      1 B| `side`
        , try debugStr(a, e6));

        ///////////////////////////// use_col == false

        try eqStr("from", tryOutWalkLineCol(a, e6, false, 0, 0));

        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 1, 0));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 1, 1));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 1, 2));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 1, 3));
        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, false, 1, 4));
        try eqStr("_venus", tryOutWalkLineCol(a, e6, false, 1, 5));
        try eqStr("venus", tryOutWalkLineCol(a, e6, false, 1, 6));
        try eqStr("enus", tryOutWalkLineCol(a, e6, false, 1, 7));
        try eqStr("nus", tryOutWalkLineCol(a, e6, false, 1, 8));
        try eqStr("us", tryOutWalkLineCol(a, e6, false, 1, 9));
        try eqStr("s", tryOutWalkLineCol(a, e6, false, 1, 10));

        try eqStr("the", tryOutWalkLineCol(a, e6, false, 2, 0));
        try eqStr("other", tryOutWalkLineCol(a, e6, false, 3, 0));
        try eqStr("side", tryOutWalkLineCol(a, e6, false, 4, 0));

        ///////////////////////////// use_col == true

        try eqStr("from", tryOutWalkLineCol(a, e6, true, 0, 0));
        try eqStr("rom", tryOutWalkLineCol(a, e6, true, 0, 1));
        try eqStr("m", tryOutWalkLineCol(a, e6, true, 0, 3));

        try eqStr("hello_venus", tryOutWalkLineCol(a, e6, true, 1, 0));
        try eqStr("ello_venus", tryOutWalkLineCol(a, e6, true, 1, 1));
        try eqStr("llo_venus", tryOutWalkLineCol(a, e6, true, 1, 2));
        try eqStr("lo_venus", tryOutWalkLineCol(a, e6, true, 1, 3));
        try eqStr("o_venus", tryOutWalkLineCol(a, e6, true, 1, 4));
        try eqStr("_venus", tryOutWalkLineCol(a, e6, true, 1, 5));
        try eqStr("venus", tryOutWalkLineCol(a, e6, true, 1, 6));
        try eqStr("enus", tryOutWalkLineCol(a, e6, true, 1, 7));
        try eqStr("nus", tryOutWalkLineCol(a, e6, true, 1, 8));
        try eqStr("us", tryOutWalkLineCol(a, e6, true, 1, 9));
        try eqStr("s", tryOutWalkLineCol(a, e6, true, 1, 10));

        try eqStr("the", tryOutWalkLineCol(a, e6, true, 2, 0));
        try eqStr("he", tryOutWalkLineCol(a, e6, true, 2, 1));

        try eqStr("side", tryOutWalkLineCol(a, e6, true, 4, 0));
        try eqStr("ide", tryOutWalkLineCol(a, e6, true, 4, 1));
        try eqStr("de", tryOutWalkLineCol(a, e6, true, 4, 2));
        try eqStr("e", tryOutWalkLineCol(a, e6, true, 4, 3));
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// walkLineColBackwards

fn walkBackwards(a: Allocator, node: RcNode, f: WalkCallback, ctx: *anyopaque) WalkError!WalkResult {
    switch (node.value.*) {
        .branch => |*branch| {
            const right = try walkBackwards(a, branch.right, f, ctx);
            if (!right.keep_walking) {
                var result = WalkResult{};
                result.found = right.found;
                if (right.replace) |r| result.replace = try Node.new(a, branch.left.retain(), r);
                return result;
            }
            const left_result = try walkBackwards(a, branch.left, f, ctx);
            return WalkResult.merge(branch, a, left_result, right);
        },
        .leaf => |*leaf| return f(ctx, leaf),
    }
}

fn walkLineColBackwards(a: Allocator, node: RcNode, line: usize, col: usize, f: F, dc: DC, ctx: *anyopaque) WalkError!WalkResult {
    switch (node.value.*) {
        .branch => |*branch| {
            // found target line
            if (line == 0) {
                const left_nocs = branch.left.value.weights().noc;
                if (col >= left_nocs) {
                    dc(ctx, left_nocs);
                    const right = try walkLineColBackwards(a, branch.right, line, col - left_nocs, f, dc, ctx);
                    if (right.found and right.keep_walking) {
                        const result = try walkBackwards(a, branch.left, f, ctx);
                        return WalkResult{ .found = true, .keep_walking = result.keep_walking };
                    }
                    return right;
                }
                return findLeftFindRight(a, branch, line, col, f, dc, ctx);
            }

            // finding target line
            const left_bols = branch.left.value.weights().bols;
            if (line >= left_bols) {
                const right = try walkLineColBackwards(a, branch.right, line - left_bols, col, f, dc, ctx);
                if (right.found and right.keep_walking) {
                    const result = try walkBackwards(a, branch.left, f, ctx);
                    return WalkResult{ .found = true, .keep_walking = result.keep_walking };
                }
                return right;
            }
            return findLeftFindRight(a, branch, line, col, f, dc, ctx);
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

fn findLeftFindRight(a: Allocator, branch: *Branch, line: usize, col: usize, f: F, dc: DC, ctx: *anyopaque) !WalkResult {
    const left = try walkLineColBackwards(a, branch.left, line, col, f, dc, ctx);
    if (left.found) return WalkResult{ .found = true, .keep_walking = left.keep_walking };
    const right = try walkLineColBackwards(a, branch.right, line, col, f, dc, ctx);
    if (right.found) return WalkResult{ .found = true, .keep_walking = right.keep_walking };
    return WalkResult{};
}

const TryOutWalkLineColBackwardsCtx = struct {
    col: usize,
    list: *ArrayList(u8),

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        try ctx.list.appendSlice(leaf.buf);
        return WalkResult.keep_walking;
    }

    fn decrementCol(ctx_: *anyopaque, decrement_col_by: usize) void {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        assert(ctx.col >= decrement_col_by);
        ctx.col -|= decrement_col_by;
    }
};

fn tryOutWalkLineColBackwards(a: Allocator, node: RcNode, line: usize, col: usize) []const u8 {
    var list = ArrayList(u8).initCapacity(a, 1024) catch unreachable;
    var ctx: TryOutWalkLineColBackwardsCtx = .{ .list = &list, .col = col };
    _ = walkLineColBackwards(a, node, line, col, TryOutWalkLineColBackwardsCtx.walker, TryOutWalkLineColBackwardsCtx.decrementCol, &ctx) catch unreachable;
    return list.toOwnedSlice() catch unreachable;
}

test tryOutWalkLineColBackwards {
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    { // unbalanced
        const root = try Node.fromString(a, &arena, "hello\nfrom\nthe\nother\nside");
        _, _, const e1 = try insertChars(root, a, &arena, "_", .{ .line = 0, .col = 5 });
        _, _, const e2 = try insertChars(e1, a, &arena, "v", .{ .line = 0, .col = 6 });
        _, _, const e3 = try insertChars(e2, a, &arena, "e", .{ .line = 0, .col = 7 });
        _, _, const e4 = try insertChars(e3, a, &arena, "n", .{ .line = 0, .col = 8 });
        _, _, const e5 = try insertChars(e4, a, &arena, "u", .{ .line = 0, .col = 9 });
        _, _, const e6 = try insertChars(e5, a, &arena, "s", .{ .line = 0, .col = 10 });

        try eqStr(
            \\9 5/31/27
            \\  8 2/17/15
            \\    7 1/12/11
            \\      1 B| `hello` Rc:6
            \\      6 0/7/6
            \\        1 `_` Rc:5
            \\        5 0/6/5
            \\          1 `v` Rc:4
            \\          4 0/5/4
            \\            1 `e` Rc:3
            \\            3 0/4/3
            \\              1 `n` Rc:2
            \\              2 0/3/2
            \\                1 `u`
            \\                1 `s` |E
            \\    1 B| `from` |E Rc:7
            \\  3 3/14/12 Rc:7
            \\    1 B| `the` |E
            \\    2 2/10/9
            \\      1 B| `other` |E
            \\      1 B| `side`
        , try debugStr(a, e6));

        try eqStr("hello", tryOutWalkLineColBackwards(a, e6, 0, 0));
        try eqStr("hello", tryOutWalkLineColBackwards(a, e6, 0, 4));
        try eqStr("_hello", tryOutWalkLineColBackwards(a, e6, 0, 5));
        try eqStr("v_hello", tryOutWalkLineColBackwards(a, e6, 0, 6));
        try eqStr("ev_hello", tryOutWalkLineColBackwards(a, e6, 0, 7));
        try eqStr("nev_hello", tryOutWalkLineColBackwards(a, e6, 0, 8));
        try eqStr("unev_hello", tryOutWalkLineColBackwards(a, e6, 0, 9));
        try eqStr("sunev_hello", tryOutWalkLineColBackwards(a, e6, 0, 10));

        try eqStr("fromsunev_hello", tryOutWalkLineColBackwards(a, e6, 1, 0));
        try eqStr("thefromsunev_hello", tryOutWalkLineColBackwards(a, e6, 2, 0));
        try eqStr("otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e6, 3, 0));
        try eqStr("sideotherthefromsunev_hello", tryOutWalkLineColBackwards(a, e6, 4, 0));

        ///////////////////////////// part 2

        _, _, const e7 = try insertChars(e6, a, &arena, " ", .{ .line = 3, .col = 5 });
        _, _, const e8 = try insertChars(e7, a, &arena, "s", .{ .line = 3, .col = 6 });
        _, _, const e9 = try insertChars(e8, a, &arena, "o", .{ .line = 3, .col = 7 });
        _, _, const e10 = try insertChars(e9, a, &arena, "m", .{ .line = 3, .col = 8 });
        _, _, const e11 = try insertChars(e10, a, &arena, "e", .{ .line = 3, .col = 9 });
        _, _, const e12 = try insertChars(e11, a, &arena, "thing", .{ .line = 3, .col = 10 });

        try eqStr(
            \\10 5/41/37
            \\  8 2/17/15 Rc:7
            \\    7 1/12/11
            \\      1 B| `hello` Rc:6
            \\      6 0/7/6
            \\        1 `_` Rc:5
            \\        5 0/6/5
            \\          1 `v` Rc:4
            \\          4 0/5/4
            \\            1 `e` Rc:3
            \\            3 0/4/3
            \\              1 `n` Rc:2
            \\              2 0/3/2
            \\                1 `u`
            \\                1 `s` |E
            \\    1 B| `from` |E Rc:7
            \\  9 3/24/22
            \\    1 B| `the` |E Rc:7
            \\    8 2/20/19
            \\      7 1/16/15
            \\        1 B| `other` Rc:6
            \\        6 0/11/10
            \\          1 ` ` Rc:5
            \\          5 0/10/9
            \\            1 `s` Rc:4
            \\            4 0/9/8
            \\              1 `o` Rc:3
            \\              3 0/8/7
            \\                1 `m` Rc:2
            \\                2 0/7/6
            \\                  1 `e`
            \\                  1 `thing` |E
            \\      1 B| `side` Rc:7
        , try debugStr(a, e12));

        try eqStr("hello", tryOutWalkLineColBackwards(a, e12, 0, 0));
        try eqStr("hello", tryOutWalkLineColBackwards(a, e12, 0, 4));
        try eqStr("_hello", tryOutWalkLineColBackwards(a, e12, 0, 5));
        try eqStr("v_hello", tryOutWalkLineColBackwards(a, e12, 0, 6));
        try eqStr("ev_hello", tryOutWalkLineColBackwards(a, e12, 0, 7));
        try eqStr("nev_hello", tryOutWalkLineColBackwards(a, e12, 0, 8));
        try eqStr("unev_hello", tryOutWalkLineColBackwards(a, e12, 0, 9));
        try eqStr("sunev_hello", tryOutWalkLineColBackwards(a, e12, 0, 10));

        try eqStr("fromsunev_hello", tryOutWalkLineColBackwards(a, e12, 1, 0));
        try eqStr("thefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 2, 0));

        try eqStr("otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 0));
        try eqStr("otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 4));
        try eqStr(" otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 5));
        try eqStr("s otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 6));
        try eqStr("os otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 7));
        try eqStr("mos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 8));
        try eqStr("emos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 9));
        try eqStr("thingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 10));
        try eqStr("thingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 14));

        try eqStr("sidethingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 4, 0));
        try eqStr("sidethingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 4, 3));
    }

    { // balanced
        const root = try Node.fromString(a, &arena, "hello\nfrom\nthe\nother\nside");
        _, _, const e1 = try insertChars(root, a, &arena, "_", .{ .line = 0, .col = 5 });
        _, _, const e2 = try insertChars(e1, a, &arena, "v", .{ .line = 0, .col = 6 });
        _, _, const e3 = try insertChars(e2, a, &arena, "e", .{ .line = 0, .col = 7 });
        _, _, const e4 = try insertChars(e3, a, &arena, "n", .{ .line = 0, .col = 8 });
        _, _, const e5 = try insertChars(e4, a, &arena, "u", .{ .line = 0, .col = 9 });
        _, _, const e6 = try insertChars(e5, a, &arena, "s", .{ .line = 0, .col = 10 });
        _, const e6b = try balance(a, e6);
        _, _, const e7 = try insertChars(e6b, a, &arena, " ", .{ .line = 3, .col = 5 });
        _, _, const e8 = try insertChars(e7, a, &arena, "s", .{ .line = 3, .col = 6 });
        _, _, const e9 = try insertChars(e8, a, &arena, "o", .{ .line = 3, .col = 7 });
        _, _, const e10 = try insertChars(e9, a, &arena, "m", .{ .line = 3, .col = 8 });
        _, _, const e11 = try insertChars(e10, a, &arena, "e", .{ .line = 3, .col = 9 });
        _, _, const e12 = try insertChars(e11, a, &arena, "thing", .{ .line = 3, .col = 10 });
        _, const e12b = try balance(a, e12);

        try eqStr(
            \\6 5/41/37
            \\  5 2/17/15
            \\    4 1/12/11 Rc:8
            \\      3 1/7/7
            \\        1 B| `hello` Rc:7
            \\        2 0/2/2
            \\          1 `_` Rc:6
            \\          1 `v` Rc:5
            \\      3 0/5/4
            \\        2 0/2/2
            \\          1 `e` Rc:4
            \\          1 `n` Rc:3
            \\        2 0/3/2 Rc:2
            \\          1 `u`
            \\          1 `s` |E
            \\    1 B| `from` |E Rc:15
            \\  5 3/24/22
            \\    4 2/11/10
            \\      1 B| `the` |E Rc:8
            \\      3 1/7/7
            \\        1 B| `other` Rc:7
            \\        2 0/2/2
            \\          1 ` ` Rc:6
            \\          1 `s` Rc:5
            \\    4 1/13/12
            \\      3 0/9/8
            \\        2 0/2/2
            \\          1 `o` Rc:4
            \\          1 `m` Rc:3
            \\        2 0/7/6 Rc:2
            \\          1 `e`
            \\          1 `thing` |E
            \\      1 B| `side` Rc:8
        , try debugStr(a, e12b));

        try eqStr("hello", tryOutWalkLineColBackwards(a, e12, 0, 0));
        try eqStr("hello", tryOutWalkLineColBackwards(a, e12, 0, 4));
        try eqStr("_hello", tryOutWalkLineColBackwards(a, e12, 0, 5));
        try eqStr("v_hello", tryOutWalkLineColBackwards(a, e12, 0, 6));
        try eqStr("ev_hello", tryOutWalkLineColBackwards(a, e12, 0, 7));
        try eqStr("nev_hello", tryOutWalkLineColBackwards(a, e12, 0, 8));
        try eqStr("unev_hello", tryOutWalkLineColBackwards(a, e12, 0, 9));
        try eqStr("sunev_hello", tryOutWalkLineColBackwards(a, e12, 0, 10));

        try eqStr("fromsunev_hello", tryOutWalkLineColBackwards(a, e12, 1, 0));
        try eqStr("thefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 2, 0));

        try eqStr("otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 0));
        try eqStr("otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 4));
        try eqStr(" otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 5));
        try eqStr("s otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 6));
        try eqStr("os otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 7));
        try eqStr("mos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 8));
        try eqStr("emos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 9));
        try eqStr("thingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 10));
        try eqStr("thingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 3, 14));

        try eqStr("sidethingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 4, 0));
        try eqStr("sidethingemos otherthefromsunev_hello", tryOutWalkLineColBackwards(a, e12, 4, 3));
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// eqRange

const EqRangeCtx = struct {
    str: []const u8,
    offset: usize = 0,
    totally_match: bool = false,

    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,

    current_line: usize,
    col: usize,

    fn decrementCol(ctx_: *anyopaque, decrement_col_by: usize) void {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        assert(ctx.col >= decrement_col_by);
        ctx.col -|= decrement_col_by;
    }

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        defer ctx.col = 0;
        assert(ctx.col <= leaf.noc);

        /////////////////////////////

        var leaf_start: ?usize = null;
        var leaf_end: ?usize = null;

        var i: usize = 0;
        var iter = code_point.Iterator{ .bytes = leaf.buf };
        while (iter.next()) |cp| {
            defer i += 1;
            if (ctx.current_line == ctx.end_line and i >= ctx.end_col) break;
            if (ctx.current_line == ctx.start_line and i < ctx.col) continue;
            if (leaf_start == null) leaf_start = cp.offset;
            leaf_end = cp.offset + cp.len;
        }

        if (leaf_start == null or leaf_end == null) return WalkResult.stop;
        const leaf_str = leaf.buf[leaf_start.?..leaf_end.?];

        if (ctx.offset + leaf_str.len > ctx.str.len) return WalkResult.stop;
        const substr_matches = eql(u8, ctx.str[ctx.offset .. ctx.offset + leaf_str.len], leaf_str);
        if (substr_matches) ctx.offset += leaf_str.len else return WalkResult.stop;

        /////////////////////////////

        const current_line_is_end_line = ctx.current_line == ctx.end_line;

        if (leaf.eol) {
            if (ctx.end_line > ctx.start_line and ctx.current_line != ctx.end_line) {
                if (ctx.str[ctx.offset] != '\n') return WalkResult.stop;
                ctx.offset += 1;
            }
            ctx.current_line += 1;
        }

        if (current_line_is_end_line) {
            if (ctx.offset == ctx.str.len) ctx.totally_match = true;
            return WalkResult.stop;
        }
        return WalkResult.keep_walking;
    }
};

pub fn eqRange(node: RcNode, start_line: usize, start_col: usize, end_line: usize, end_col: usize, str: []const u8) bool {
    assert(end_line >= start_line);
    assert(if (start_line == end_line) end_col > start_col else true);
    if (end_line < start_line or (start_line == end_line and end_col <= start_col)) return false;

    var ctx: EqRangeCtx = .{
        .str = str,
        .start_line = start_line,
        .start_col = start_col,
        .end_line = end_line,
        .end_col = end_col,
        .current_line = start_line,
        .col = start_col,
    };
    _ = walkLineCol(std.heap.page_allocator, node, start_line, start_col, EqRangeCtx.walker, EqRangeCtx.decrementCol, &ctx) catch unreachable;
    return ctx.totally_match;
}

test eqRange {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const root = try Node.fromString(a, &arena,
            \\const Allocator = std.mem.Allocator;
            \\var x = 10;
            \\var y = 20;
        );

        // single line
        try eq(true, eqRange(root, 0, 0, 0, 1, "c"));
        try eq(true, eqRange(root, 0, 0, 0, 5, "const"));
        try eq(true, eqRange(root, 0, 6, 0, 15, "Allocator"));
        try eq(true, eqRange(root, 0, 18, 0, 36, "std.mem.Allocator;"));

        try eq(false, eqRange(root, 0, 0, 0, 1, "z"));
        try eq(false, eqRange(root, 0, 0, 0, 5, "onst"));
        try eq(false, eqRange(root, 0, 18, 0, 36, "std.mem.Allocator;x"));

        // 2 lines
        try eq(true, eqRange(root, 0, 18, 1, 1, "std.mem.Allocator;\nv"));
        try eq(false, eqRange(root, 0, 18, 1, 1, "std.mem.Allocator;\n"));
        try eq(false, eqRange(root, 0, 18, 1, 1, "std.mem.Allocator;\nx"));

        // 3 lines
        try eq(true, eqRange(root, 0, 18, 2, 1, "std.mem.Allocator;\nvar x = 10;\nv"));
        try eq(false, eqRange(root, 0, 18, 2, 1, "std.mem.Allocator;\nvar x = 10;\n"));
        try eq(false, eqRange(root, 0, 18, 2, 1, "std.mem.Allocator;\nvar x = 10;\nvo"));
        try eq(false, eqRange(root, 0, 18, 2, 1, "std.mem.Allocator;\nvar x = 10;\nva"));
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
    noc: u32,

    fn new(a: Allocator, source: []const u8, bol: bool, eol: bool) !RcNode {
        return try RcNode.init(a, .{
            .leaf = .{ .buf = source, .bol = bol, .eol = eol, .noc = getNumOfChars(source) },
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
            .depth = 1,
            .bols = if (self.bol) 1 else 0,
            .noc = self.noc,
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
    noc: u32 = 0,

    fn add(self: *Weights, other: Weights) void {
        self.bols += other.bols;
        self.len += other.len;
        self.noc += other.noc;
        self.depth = @max(self.depth, other.depth);
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

    pub fn isEmpty(self: *const @This()) bool {
        return self.start.line == self.end.line and self.start.col == self.end.col;
    }

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

    try eq(16, @sizeOf(Weights));
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

fn eqStrU21(expected: []const u8, got: []const u21) !void {
    var slice = try testing_allocator.alloc(u8, got.len);
    defer testing_allocator.free(slice);
    for (got, 0..) |cp, i| slice[i] = @intCast(cp);
    try eqStr(expected, slice);
}

fn releaseChildrenRecursive(self: *const Node, a: Allocator) void {
    if (self.* == .leaf) return;
    if (self.branch.left.strongCount() == 1) releaseChildrenRecursive(self.branch.left.value, a);
    self.branch.left.release(a);
    if (self.branch.right.strongCount() == 1) releaseChildrenRecursive(self.branch.right.value, a);
    self.branch.right.release(a);
}
