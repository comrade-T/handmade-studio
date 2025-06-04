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
const shouldErr = std.testing.expectError;

pub const EolMode = enum { lf, crlf };

//////////////////////////////////////////////////////////////////////////////////////////////

const WalkError = error{OutOfMemory};
const WalkCallback = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkError!WalkResult;

const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkError!WalkResult;
const DC = *const fn (ctx: *anyopaque, decrement_col_by: usize) void;

const KEEP_WALKING = WalkResult{ .keep_walking = true };
const STOP = WalkResult{ .keep_walking = false };
const FOUND = WalkResult{ .found = true };

const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    replace: ?RcNode = null,

    fn merge(branch: *const Branch, a: Allocator, left: WalkResult, right: WalkResult) WalkError!WalkResult {
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
            return KEEP_WALKING;
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
        var s = try ArrayList(u8).initCapacity(a, self.weights().len);
        try self.store(s.writer(), eol_mode);
        return s.toOwnedSlice();
    }

    test toString {
        var arena = std.heap.ArenaAllocator.init(idc_if_it_leaks);
        defer arena.deinit();

        const root = try Node.fromString(idc_if_it_leaks, arena.allocator(), "hello world");
        try eqStr("hello world", try root.value.toString(idc_if_it_leaks, .lf));

        const r1 = try insertChars(root, idc_if_it_leaks, arena.allocator(), "// ", .{ .line = 0, .col = 0 });
        try eqStr("// hello world", try r1.node.value.toString(idc_if_it_leaks, .lf));
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

    pub fn fromString(a: Allocator, content_allocator: Allocator, source: []const u8) !RcNode {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, content_allocator, stream.reader(), source.len);
    }

    pub fn fromFile(a: Allocator, content_allocator: Allocator, path: []const u8) !RcNode {
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        return Node.fromReader(a, content_allocator, file.reader(), stat.size);
    }

    test fromString {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        {
            const root = try Node.fromString(testing_allocator, content_arena.allocator(), "");
            defer freeRcNode(testing_allocator, root);
            try eqStr(
                \\1 B| ``
            , try debugStr(idc_if_it_leaks, root));
            try eq(true, root.value.* == .leaf);
        }
        {
            const root = try Node.fromString(testing_allocator, content_arena.allocator(), "hello\nworld");
            defer freeRcNode(testing_allocator, root);
            try eqStr(
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world`
            , try debugStr(idc_if_it_leaks, root));
        }
    }

    fn fromReader(a: Allocator, content_allocator: Allocator, reader: anytype, buffer_size: usize) !RcNode {
        const buf = try content_allocator.alloc(u8, buffer_size);

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

const SINGLE_CHARS = [_][]const u8{
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 0-15
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 16-31
    " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/", // 32-47
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?", // 48-63
    "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", // 64-79
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_", // 80-95
    "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", // 96-111
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "", // 112-127
    // Remaining values (128-255) are non-readable in ASCII, so they will be empty strings
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 128-143
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 144-159
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 160-175
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 176-191
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 192-207
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 208-223
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 224-239
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 240-255
};

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
        return if (leaf.eol) STOP else KEEP_WALKING;
    }
};

const InsertCharsError = error{ OutOfMemory, InputLenZero, ColumnOutOfBounds };
pub const InsertCharsResult = struct {
    allocated_str: []const u8,
    new_line: usize,
    new_col: usize,
    node: RcNode,
};
const EMPTY_STR = "";
pub fn insertChars(self_: RcNode, a: Allocator, content_allocator: Allocator, chars: []const u8, destination: EditPoint) InsertCharsError!InsertCharsResult {
    if (chars.len == 0) return error.InputLenZero;
    var self = self_;

    var allocated_str: []const u8 = EMPTY_STR;
    var rest = if (chars.len == 1 and chars[0] != '\n')
        SINGLE_CHARS[chars[0]]
    else blk: {
        const duped = try content_allocator.dupe(u8, chars);
        allocated_str = duped;
        break :blk duped;
    };

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

    return InsertCharsResult{
        .allocated_str = allocated_str,
        .new_line = line,
        .new_col = col,
        .node = self,
    };
}

test "insertChars - single insertion at beginning" {
    // freeing last history first
    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        const old_root = try Node.fromString(testing_allocator, content_arena.allocator(), "hello\nworld");
        defer freeRcNode(testing_allocator, old_root);
        try eqStr(
            \\2 2/11/10
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(idc_if_it_leaks, old_root));

        {
            const result = try insertChars(old_root, testing_allocator, content_arena.allocator(), "ok ", .{ .line = 0, .col = 0 });
            defer freeRcNode(testing_allocator, result.node);

            try eqStr(
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, old_root));

            try eq(.{ 0, 3 }, .{ result.new_line, result.new_col });
            try eqStr(
                \\3 2/14/13
                \\  2 1/9/8
                \\    1 B| `ok `
                \\    1 `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, result.node));
        }
    }

    // freeing first history first
    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();

        // before
        const old_root = try Node.fromString(testing_allocator, content_arena.allocator(), "hello\nworld");
        try eqStr(
            \\2 2/11/10
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(idc_if_it_leaks, old_root));

        // after insertChars()
        const result = try insertChars(old_root, testing_allocator, content_arena.allocator(), "ok ", .{ .line = 0, .col = 0 });
        {
            try eqStr(
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, old_root));

            try eq(.{ 0, 3 }, .{ result.new_line, result.new_col });
            try eqStr(
                \\3 2/14/13
                \\  2 1/9/8
                \\    1 B| `ok `
                \\    1 `hello` |E
                \\  1 B| `world` Rc:2
            , try debugStr(idc_if_it_leaks, result.node));
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
            , try debugStr(idc_if_it_leaks, result.node));
        }

        // freeing new_root later
        freeRcNode(testing_allocator, result.node);
    }
}

test "insertChars - insert in middle of leaf" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, content_arena.allocator(), "hello");

    // `hello` -> `he3llo`
    const r1 = try insertChars(original, testing_allocator, content_arena.allocator(), "3", .{ .line = 0, .col = 2 });
    try eq(.{ 0, 3 }, .{ r1.new_line, r1.new_col });
    try eqStr(
        \\3 1/6/6
        \\  1 B| `he`
        \\  2 0/4/4
        \\    1 `3`
        \\    1 `llo`
    , try debugStr(idc_if_it_leaks, r1.node));

    // `he3llo` -> `he3ll0o`
    const r2 = try insertChars(r1.node, testing_allocator, content_arena.allocator(), "0", .{ .line = 0, .col = 5 });
    try eq(.{ 0, 6 }, .{ r2.new_line, r2.new_col });
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
    , try debugStr(idc_if_it_leaks, r2.node));

    // `he3ll0o` -> `he3ll\n0o`
    const r3 = try insertChars(r2.node, testing_allocator, content_arena.allocator(), "\n", .{ .line = 0, .col = 5 });
    try eq(.{ 1, 0 }, .{ r3.new_line, r3.new_col });
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
    , try debugStr(idc_if_it_leaks, r3.node));

    freeRcNodes(testing_allocator, &.{ original, r1.node, r2.node, r3.node });
}

test "insertChars - multiple insertions from empty string" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();
    const a = testing_allocator;

    // original
    const r0 = try Node.fromString(a, content_arena.allocator(), "");
    try eqStr(
        \\1 B| ``
    , try debugStr(idc_if_it_leaks, r0));

    // 1st edit
    const res1 = try insertChars(r0, a, content_arena.allocator(), "h", .{ .line = 0, .col = 0 });
    {
        try eqStr(
            \\1 B| ``
        , try debugStr(idc_if_it_leaks, r0));

        try eq(.{ 0, 1 }, .{ res1.new_line, res1.new_col });
        try eqStr(
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, res1.node));
    }

    // 2st edit
    const res2 = try insertChars(res1.node, a, content_arena.allocator(), "e", .{ .line = res1.new_line, .col = res1.new_col });
    {
        try eqStr(
            \\1 B| ``
        , try debugStr(idc_if_it_leaks, r0));

        try eqStr(
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, res1.node));

        try eq(.{ 0, 2 }, .{ res2.new_line, res2.new_col });
        try eqStr(
            \\2 1/2/2
            \\  1 B| `h`
            \\  1 `e`
        , try debugStr(idc_if_it_leaks, res2.node));
    }

    const res3 = try insertChars(res2.node, a, content_arena.allocator(), "l", .{ .line = res2.new_line, .col = res2.new_col });
    // 3rd edit
    {
        try eqStr(
            \\1 B| ``
        , try debugStr(idc_if_it_leaks, r0));

        try eqStr(
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, res1.node));

        try eqStr(
            \\2 1/2/2
            \\  1 B| `h` Rc:2
            \\  1 `e`
        , try debugStr(idc_if_it_leaks, res2.node));

        try eq(.{ 0, 3 }, .{ res3.new_line, res3.new_col });
        try eqStr(
            \\3 1/3/3
            \\  1 B| `h` Rc:2
            \\  2 0/2/2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, res3.node));
    }

    const res4 = try insertChars(res3.node, a, content_arena.allocator(), "3", .{ .line = 0, .col = 1 });
    // 4rd edit
    {
        try eqStr(
            \\1 B| ``
        , try debugStr(idc_if_it_leaks, r0));

        try eqStr(
            \\2 1/1/1
            \\  1 B| `h`
            \\  1 ``
        , try debugStr(idc_if_it_leaks, res1.node));

        try eqStr(
            \\2 1/2/2
            \\  1 B| `h` Rc:2
            \\  1 `e`
        , try debugStr(idc_if_it_leaks, res2.node));

        try eqStr(
            \\3 1/3/3
            \\  1 B| `h` Rc:2
            \\  2 0/2/2 Rc:2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, res3.node));

        try eq(.{ 0, 2 }, .{ res4.new_line, res4.new_col });
        try eqStr(
            \\3 1/4/4
            \\  2 1/2/2
            \\    1 B| `h`
            \\    1 `3`
            \\  2 0/2/2 Rc:2
            \\    1 `e`
            \\    1 `l`
        , try debugStr(idc_if_it_leaks, res4.node));
    }

    const res5 = try insertChars(res4.node, a, content_arena.allocator(), "// ", .{ .line = 0, .col = 0 });
    {
        try eq(.{ 0, 3 }, .{ res5.new_line, res5.new_col });
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
        , try debugStr(idc_if_it_leaks, res5.node));
    }

    const res6a = try insertChars(res5.node, a, content_arena.allocator(), "o", .{ .line = 0, .col = 7 });
    {
        try eq(.{ 0, 8 }, .{ res6a.new_line, res6a.new_col });
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
        , try debugStr(idc_if_it_leaks, res6a.node));
    }

    const res6b = try insertChars(res5.node, a, content_arena.allocator(), "x", .{ .line = 0, .col = 6 });
    {
        try eq(.{ 0, 7 }, .{ res6b.new_line, res6b.new_col });
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
        , try debugStr(idc_if_it_leaks, res6b.node));
    }

    const res6c = try insertChars(res5.node, a, content_arena.allocator(), "x", .{ .line = 0, .col = 5 });
    {
        try eq(.{ 0, 6 }, .{ res6c.new_line, res6c.new_col });
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
        , try debugStr(idc_if_it_leaks, res6c.node));
    }

    freeRcNodes(testing_allocator, &.{ r0, res1.node, res2.node, res3.node, res4.node, res5.node, res6a.node, res6b.node });

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
    , try debugStr(idc_if_it_leaks, res6c.node));

    freeRcNode(testing_allocator, res6c.node);
}

test "insertChars - abcd" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const acd = try Node.fromString(testing_allocator, content_arena.allocator(), "ACD");
    defer freeRcNode(testing_allocator, acd);

    const abcd = try insertChars(acd, testing_allocator, content_arena.allocator(), "B", .{ .line = 0, .col = 1 });
    defer freeRcNode(testing_allocator, abcd.node);
    const abcd_dbg =
        \\3 1/4/4
        \\  1 B| `A`
        \\  2 0/3/3
        \\    1 `B`
        \\    1 `CD`
    ;
    try eqStr(abcd_dbg, try debugStr(idc_if_it_leaks, abcd.node));

    {
        const eabcd = try insertChars(abcd.node, testing_allocator, content_arena.allocator(), "E", .{ .line = 0, .col = 0 });
        defer freeRcNode(testing_allocator, eabcd.node);
        const eabcd_dbg =
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `E`
            \\    1 `A`
            \\  2 0/3/3 Rc:2
            \\    1 `B`
            \\    1 `CD`
        ;
        try eqStr(eabcd_dbg, try debugStr(idc_if_it_leaks, eabcd.node));
    }

    {
        const abcde = try insertChars(abcd.node, testing_allocator, content_arena.allocator(), "E", .{ .line = 0, .col = 4 });
        defer freeRcNode(testing_allocator, abcde.node);
        const abcde_dbg =
            \\4 1/5/5
            \\  1 B| `A` Rc:2
            \\  3 0/4/4
            \\    1 `B` Rc:2
            \\    2 0/3/3
            \\      1 `CD`
            \\      1 `E`
        ;
        try eqStr(abcde_dbg, try debugStr(idc_if_it_leaks, abcde.node));
    }
}

test "insertChars - with newline \n" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();
    const a = testing_allocator;

    // original
    const r0 = try Node.fromString(a, content_arena.allocator(), "hello venus");
    try eqStr(
        \\1 B| `hello venus`
    , try debugStr(idc_if_it_leaks, r0));

    // 1st edit
    const res1 = try insertChars(r0, a, content_arena.allocator(), "\n", .{ .line = 0, .col = 11 });
    {
        try eqStr(
            \\1 B| `hello venus`
        , try debugStr(idc_if_it_leaks, r0));

        try eq(.{ 1, 0 }, .{ res1.new_line, res1.new_col });
        try eqStr(
            \\3 2/12/11
            \\  1 B| `hello venus`
            \\  2 1/1/0
            \\    1 `` |E
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, res1.node));
    }

    // 2nd edit
    const res2 = try insertChars(res1.node, a, content_arena.allocator(), "ok", .{ .line = 1, .col = 0 });
    {
        try eqStr(
            \\3 2/12/11
            \\  1 B| `hello venus` Rc:2
            \\  2 1/1/0
            \\    1 `` |E Rc:2
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, res1.node));

        try eq(.{ 1, 2 }, .{ res2.new_line, res2.new_col });
        try eqStr(
            \\4 2/14/13
            \\  1 B| `hello venus` Rc:2
            \\  3 1/3/2
            \\    1 `` |E Rc:2
            \\    2 1/2/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, res2.node));
    }

    // 3rd edit
    const res3 = try insertChars(res2.node, a, content_arena.allocator(), "\nfine", .{ .line = res2.new_line, .col = res2.new_col });
    {
        try eqStr(
            \\3 2/12/11
            \\  1 B| `hello venus` Rc:3
            \\  2 1/1/0
            \\    1 `` |E Rc:3
            \\    1 B| ``
        , try debugStr(idc_if_it_leaks, res1.node));

        try eqStr(
            \\4 2/14/13
            \\  1 B| `hello venus` Rc:3
            \\  3 1/3/2
            \\    1 `` |E Rc:3
            \\    2 1/2/2
            \\      1 B| `ok`
            \\      1 ``
        , try debugStr(idc_if_it_leaks, res2.node));

        try eq(.{ 2, 4 }, .{ res3.new_line, res3.new_col });
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
        , try debugStr(idc_if_it_leaks, res3.node));
    }

    freeRcNodes(testing_allocator, &.{ r0, res1.node, res2.node, res3.node });
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

fn insertCharOneAfterAnother(a: Allocator, content_allocator: Allocator, str: []const u8, should_balance: bool) !ArrayList(RcNode) {
    var list = try ArrayList(RcNode).initCapacity(a, str.len + 1);
    var node = try Node.fromString(a, content_allocator, "");
    try list.append(node);
    var line: usize = 0;
    var col: usize = 0;
    for (str) |char| {
        const result = try insertChars(node, a, content_allocator, &.{char}, .{ .line = line, .col = col });
        line, col, node = .{ result.new_line, result.new_col, result.node };
        if (should_balance) {
            const is_balanced, const balanced_node = try balance(a, node);
            if (is_balanced) {
                freeRcNode(a, node);
                node = balanced_node;
            }
        }
        try list.append(result.node);
    }
    return list;
}

fn freeBackAndForth(str: []const u8) !void {
    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        var iterations = try insertCharOneAfterAnother(testing_allocator, content_arena.allocator(), str, false);
        defer iterations.deinit();
        for (0..iterations.items.len) |i| freeRcNode(testing_allocator, iterations.items[i]);
    }

    {
        var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer content_arena.deinit();
        var iterations = try insertCharOneAfterAnother(testing_allocator, content_arena.allocator(), str, false);
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
        var result = KEEP_WALKING;

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

pub fn deleteChars(self: RcNode, a: Allocator, destination: EditPoint, count: usize) error{ OutOfMemory, Stop, NotFound }!RcNode {
    assert(count > 0);
    var ctx = DeleteCharsCtx{ .a = a, .col = destination.col, .count = count };
    const result = try walkFromLineBegin(a, self, destination.line, DeleteCharsCtx.walker, &ctx);
    if (result.found) return result.replace orelse error.Stop;
    return error.NotFound;
}

test "deleteChars - basics" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const original = try Node.fromString(testing_allocator, content_arena.allocator(), "1234567");
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

    const original = try Node.fromString(testing_allocator, content_arena.allocator(), "hello venus\nhello world\nhello kitty");
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

    const original = try Node.fromString(testing_allocator, content_arena.allocator(), "hello venus\nhello world\nhello kitty");
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
            return FOUND;
        }
        return KEEP_WALKING;
    }
};

pub fn getNocOfRange(node: RcNode, start: EditPoint, end: EditPoint) usize {
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

    const original = try Node.fromString(testing_allocator, content_arena.allocator(), "hello venus\nhello world\nhello kitty");
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

    const root = try Node.fromString(testing_allocator, content_arena.allocator(), "");

    const res1 = try insertChars(root, testing_allocator, content_arena.allocator(), "1", .{ .line = 0, .col = 0 });
    try eq(.{ false, res1.node }, try balance(testing_allocator, res1.node));

    const res2 = try insertChars(res1.node, testing_allocator, content_arena.allocator(), "2", .{ .line = 0, .col = 1 });
    try eq(.{ false, res1.node }, try balance(testing_allocator, res1.node));

    const res3 = try insertChars(res2.node, testing_allocator, content_arena.allocator(), "3", .{ .line = 0, .col = 2 });
    try eq(.{ false, res1.node }, try balance(testing_allocator, res1.node));

    ///////////////////////////// e4

    const res4 = try insertChars(res3.node, testing_allocator, content_arena.allocator(), "4", .{ .line = 0, .col = 3 });
    try eqStr( // unbalanced
        \\4 1/4/4
        \\  1 B| `1` Rc:3
        \\  3 0/3/3
        \\    1 `2` Rc:2
        \\    2 0/2/2
        \\      1 `3`
        \\      1 `4`
    , try debugStr(idc_if_it_leaks, res4.node));

    const e4_has_changes, const e4_balanced = try balance(testing_allocator, res4.node);
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

    // ///////////////////////////// e5

    const res5 = try insertChars(res4.node, testing_allocator, content_arena.allocator(), "5", .{ .line = 0, .col = 4 });
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
    , try debugStr(idc_if_it_leaks, res5.node));

    const e5_has_changes, const e5_balanced = try balance(testing_allocator, res5.node);
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

    // ///////////////////////////// e6

    const res6 = try insertChars(res5.node, testing_allocator, content_arena.allocator(), "6", .{ .line = 0, .col = 5 });
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
    , try debugStr(idc_if_it_leaks, res6.node));

    const e6_has_changes, const e6_balanced = try balance(testing_allocator, res6.node);
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

    freeRcNodes(testing_allocator, &.{ root, res1.node, res2.node, res3.node, res4.node, e4_balanced, res5.node, e5_balanced, res6.node, e6_balanced });
}

test "insert at beginning then balance, one character at a time" {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();

    const root = try Node.fromString(testing_allocator, content_arena.allocator(), "hello world");

    const res1 = try insertChars(root, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    try eq(.{ false, res1.node }, try balance(testing_allocator, res1.node));

    const res2 = try insertChars(res1.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    try eq(.{ false, res2.node }, try balance(testing_allocator, res2.node));

    ///////////////////////////// e3

    const res3 = try insertChars(res2.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    freeRcNodes(testing_allocator, &.{ root, res1.node, res2.node });
    try eqStr(
        \\4 1/14/14
        \\  3 1/3/3
        \\    2 1/2/2
        \\      1 B| `/`
        \\      1 `/`
        \\    1 `/`
        \\  1 `hello world`
    , try debugStr(idc_if_it_leaks, res3.node));

    const e3_rebalanced, const e3b = try balance(testing_allocator, res3.node);
    {
        try eq(true, e3_rebalanced);
        freeRcNode(testing_allocator, res3.node);
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

    // ///////////////////////////// e4

    const res4 = try insertChars(e3b, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res4.node));

    const e4_rebalanced, _ = try balance(testing_allocator, res4.node);
    try eq(false, e4_rebalanced);

    // ///////////////////////////// e5

    const res5 = try insertChars(res4.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, res4.node);
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
    , try debugStr(idc_if_it_leaks, res5.node));

    const e5_rebalanced, const e5b = try balance(testing_allocator, res5.node);
    {
        try eq(true, e5_rebalanced);
        freeRcNode(testing_allocator, res5.node);
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

    // ///////////////////////////// e6

    const res6 = try insertChars(e5b, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res6.node));

    const e6_rebalanced, const e6b = try balance(testing_allocator, res6.node);
    {
        try eq(true, e6_rebalanced);
        freeRcNode(testing_allocator, res6.node);
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

    // ///////////////////////////// e7

    const res7 = try insertChars(e6b, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res7.node));

    const e7_rebalanced, _ = try balance(testing_allocator, res7.node);
    try eq(false, e7_rebalanced);

    // ///////////////////////////// e8

    const res8 = try insertChars(res7.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, res7.node);
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
    , try debugStr(idc_if_it_leaks, res8.node));

    const e8_rebalanced, const e8b = try balance(testing_allocator, res8.node);
    {
        try eq(true, e8_rebalanced);
        freeRcNode(testing_allocator, res8.node);
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

    // ///////////////////////////// e9

    const res9 = try insertChars(e8b, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res9.node));

    const e9_rebalanced, _ = try balance(testing_allocator, res9.node);
    try eq(false, e9_rebalanced);

    // ///////////////////////////// e10

    const res10 = try insertChars(res9.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, res9.node);
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
    , try debugStr(idc_if_it_leaks, res10.node));

    const e10_rebalanced, const e10b = try balance(testing_allocator, res10.node);
    {
        try eq(true, e10_rebalanced);
        freeRcNode(testing_allocator, res10.node);
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

    // ///////////////////////////// e11

    const res11 = try insertChars(e10b, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res11.node));

    const e11_rebalanced, _ = try balance(testing_allocator, res11.node);
    try eq(false, e11_rebalanced);

    // ///////////////////////////// e12

    const res12 = try insertChars(res11.node, testing_allocator, content_arena.allocator(), "/", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, res11.node);
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
    , try debugStr(idc_if_it_leaks, res12.node));

    const e12_rebalanced, const e12b = try balance(testing_allocator, res12.node);
    {
        try eq(true, e12_rebalanced);
        freeRcNode(testing_allocator, res12.node);
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

    // ///////////////////////////// e13

    const res13 = try insertChars(e12b, testing_allocator, content_arena.allocator(), "a", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res13.node));

    const e13_rebalanced, _ = try balance(testing_allocator, res13.node);
    try eq(false, e13_rebalanced);

    // ///////////////////////////// e14

    const res14 = try insertChars(res13.node, testing_allocator, content_arena.allocator(), "a", .{ .line = 0, .col = 0 });
    freeRcNode(testing_allocator, res13.node);
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
    , try debugStr(idc_if_it_leaks, res14.node));

    const e14_rebalanced, const e14b = try balance(testing_allocator, res14.node);
    {
        try eq(true, e14_rebalanced);
        freeRcNode(testing_allocator, res14.node);
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

    const root = try Node.fromFile(testing_allocator, content_arena.allocator(), "src/window/fixtures/dummy_3_lines.zig");

    var list = ArrayList(RcNode).init(testing_allocator);
    defer list.deinit();

    ///////////////////////////// e1

    const res1 = try insertChars(root, testing_allocator, content_arena.allocator(), "1", .{ .line = 0, .col = 0 });
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
    , try debugStr(idc_if_it_leaks, res1.node));

    try eq(.{ false, res1.node }, try balance(testing_allocator, res1.node));

    ///////////////////////////// e2

    const res2 = try insertChars(res1.node, testing_allocator, content_arena.allocator(), "2", .{ .line = res1.new_line, .col = res1.new_col });
    try list.append(res1.node);
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
    , try debugStr(idc_if_it_leaks, res2.node));

    const e2_has_changes, const e2b = try balance(testing_allocator, res2.node);
    {
        try eq(true, e2_has_changes);
        freeRcNode(testing_allocator, res2.node);
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

    // ///////////////////////////// e3

    const res3 = try insertChars(e2b, testing_allocator, content_arena.allocator(), "3", .{ .line = res2.new_line, .col = res2.new_col });
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
    , try debugStr(idc_if_it_leaks, res3.node));

    const e3_has_changes, const e3b = try balance(testing_allocator, res3.node);
    {
        try eq(true, e3_has_changes);
        freeRcNode(testing_allocator, res3.node);
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

    // ///////////////////////////// e4

    const res4 = try insertChars(e3b, testing_allocator, content_arena.allocator(), "4", .{ .line = res3.new_line, .col = res3.new_col });
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
    , try debugStr(idc_if_it_leaks, res4.node));

    try eq(.{ false, res4.node }, try balance(testing_allocator, res4.node));

    // ///////////////////////////// e5

    const res5 = try insertChars(res4.node, testing_allocator, content_arena.allocator(), "5", .{ .line = res4.new_line, .col = res4.new_col });
    try list.append(res4.node);
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
    , try debugStr(idc_if_it_leaks, res5.node));

    const e5_has_changes, const e5b = try balance(testing_allocator, res5.node);
    {
        try eq(true, e5_has_changes);
        freeRcNode(testing_allocator, res5.node);
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

    // ///////////////////////////// e6

    const res6 = try insertChars(e5b, testing_allocator, content_arena.allocator(), "6", .{ .line = res5.new_line, .col = res5.new_col });
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
    , try debugStr(idc_if_it_leaks, res6.node));

    try eq(.{ false, res6.node }, try balance(testing_allocator, res6.node));

    // ///////////////////////////// e7

    const res7 = try insertChars(res6.node, testing_allocator, content_arena.allocator(), "7", .{ .line = res6.new_line, .col = res6.new_col });
    try list.append(res6.node);
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
    , try debugStr(idc_if_it_leaks, res7.node));

    const e7_has_changes, const e7b = try balance(testing_allocator, res7.node);
    {
        try eq(true, e7_has_changes);
        freeRcNode(testing_allocator, res7.node);
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

    // ///////////////////////////// e8

    const res8 = try insertChars(e7b, testing_allocator, content_arena.allocator(), "8", .{ .line = res7.new_line, .col = res7.new_col });
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
    , try debugStr(idc_if_it_leaks, res8.node));

    try eq(.{ false, res8.node }, try balance(testing_allocator, res8.node));

    // ////////////////////////////////////////////////////////// e9

    const res9 = try insertChars(res8.node, testing_allocator, content_arena.allocator(), "9", .{ .line = res8.new_line, .col = res8.new_col });
    try list.append(res8.node);

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
    , try debugStr(idc_if_it_leaks, res9.node));

    const e9_has_changes, const e9b = try balance(testing_allocator, res9.node);
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
    , try debugStr(idc_if_it_leaks, res9.node));

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
            freeRcNode(testing_allocator, res9.node);
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

    const acd = try Node.fromString(testing_allocator, content_arena.allocator(), "ACD");
    const abcd = try insertChars(acd, testing_allocator, content_arena.allocator(), "B", .{ .line = 0, .col = 1 });
    const abcde = try insertChars(abcd.node, testing_allocator, content_arena.allocator(), "E", .{ .line = 0, .col = 4 });

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
        , try debugStr(idc_if_it_leaks, abcd.node));

        try eqStr(
            \\4 1/5/5
            \\  1 B| `A` Rc:2
            \\  3 0/4/4
            \\    1 `B` Rc:2
            \\    2 0/3/3
            \\      1 `CD`
            \\      1 `E`
        , try debugStr(idc_if_it_leaks, abcde.node));
    }

    ///////////////////////////// after rotateLeft

    const abcde_rotated = try rotateLeft(testing_allocator, abcde.node);
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
        , try debugStr(idc_if_it_leaks, abcd.node));

        try eqStr(
            \\4 1/5/5
            \\  1 B| `A` Rc:3
            \\  3 0/4/4
            \\    1 `B` Rc:3
            \\    2 0/3/3 Rc:2
            \\      1 `CD`
            \\      1 `E`
        , try debugStr(idc_if_it_leaks, abcde.node));
    }

    freeRcNodes(testing_allocator, &.{ acd, abcd.node, abcde.node, abcde_rotated });
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

    const def = try Node.fromString(testing_allocator, content_arena.allocator(), "DEF");
    const cdef = try insertChars(def, testing_allocator, content_arena.allocator(), "C", .{ .line = 0, .col = 0 });
    const bcdef = try insertChars(cdef.node, testing_allocator, content_arena.allocator(), "B", .{ .line = 0, .col = 0 });
    const abcdef = try insertChars(bcdef.node, testing_allocator, content_arena.allocator(), "A", .{ .line = 0, .col = 0 });

    // sanity check
    {
        try eqStr(
            \\1 B| `DEF`
        , try debugStr(idc_if_it_leaks, def));

        try eqStr(
            \\2 1/4/4
            \\  1 B| `C`
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, cdef.node));

        try eqStr(
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `B`
            \\    1 `C` Rc:2
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, bcdef.node));

        try eqStr(
            \\4 1/6/6
            \\  3 1/3/3
            \\    2 1/2/2
            \\      1 B| `A`
            \\      1 `B`
            \\    1 `C` Rc:2
            \\  1 `DEF` Rc:3
        , try debugStr(idc_if_it_leaks, abcdef.node));
    }

    ///////////////////////////// after rotateRight

    const abcdef_rotated = try rotateRight(testing_allocator, abcdef.node);
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
        , try debugStr(idc_if_it_leaks, cdef.node));

        try eqStr(
            \\3 1/5/5
            \\  2 1/2/2
            \\    1 B| `B`
            \\    1 `C` Rc:3
            \\  1 `DEF` Rc:4
        , try debugStr(idc_if_it_leaks, bcdef.node));

        try eqStr(
            \\4 1/6/6
            \\  3 1/3/3
            \\    2 1/2/2 Rc:2
            \\      1 B| `A`
            \\      1 `B`
            \\    1 `C` Rc:3
            \\  1 `DEF` Rc:4
        , try debugStr(idc_if_it_leaks, abcdef.node));
    }

    freeRcNodes(testing_allocator, &.{ def, cdef.node, bcdef.node, abcdef.node, abcdef_rotated });
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
                    var left = KEEP_WALKING;
                    const left_branch_contains_target = branch.left.value.weights().len + cx.target_byte_offset >= cx.target_byte_offset;
                    if (left_branch_contains_target) {
                        left = try cx.walk(branch.left);
                    } else {
                        cx.current_byte_offset += branch.left.value.weights().len;
                        cx.line += branch.left.value.weights().bols;
                    }
                    if (left.keep_walking == false) return STOP;

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
                return STOP;
            }

            cx.current_byte_offset += leaf.weights().len;
            cx.col += leaf.noc;
            if (leaf.eol) cx.line += 1;
            return KEEP_WALKING;
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
        const root = try Node.fromString(a, arena.allocator(), "123456789");
        try eq(.{ 0, 0 }, getPositionFromByteOffset(root, 0));
        try eq(.{ 0, 1 }, getPositionFromByteOffset(root, 1));
        try eq(.{ 0, 5 }, getPositionFromByteOffset(root, 5));
    }
    {
        const source = "one\ntwo\nthree\nfour";
        const root = try Node.fromString(a, arena.allocator(), source);

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
        const root = try __inputCharsOneAfterAnotherAt0Position(a, arena.allocator(), reverse_input_sequence);
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
            if (cx.should_stop) return STOP;

            switch (node.value.*) {
                .branch => |*branch| {
                    const left_bols_end = cx.current_line + branch.left.value.weights().bols;

                    var left = KEEP_WALKING;
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
                return KEEP_WALKING;
            }

            if (leaf.bol) cx.encountered_bol = true;

            if (cx.encountered_bol and cx.target_col == 0) {
                cx.should_stop = true;
                return STOP;
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
                return STOP;
            }

            if (leaf.eol) cx.byte_offset += 1;
            return KEEP_WALKING;
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
        const root = try Node.fromString(a, arena.allocator(), "Hello World!");
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
        const root = try Node.fromString(a, arena.allocator(), source);

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
        const nodes = try insertCharOneAfterAnother(idc_if_it_leaks, arena.allocator(), source, false);
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
        const root = try __inputCharsOneAfterAnotherAt0Position(a, arena.allocator(), reverse_input_sequence);
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

fn __inputCharsOneAfterAnotherAt0Position(a: Allocator, content_allocator: Allocator, chars: []const u8) !RcNode {
    var root = try Node.fromString(a, content_allocator, "");
    for (0..chars.len) |i| {
        const result = try insertChars(root, a, content_allocator, chars[i .. i + 1], .{ .line = 0, .col = 0 });
        root = result.node;
    }
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
                return STOP;
            };
            ctx.col = 0;
            return STOP;
        }

        if (!leaf.eol and leaf.noc < ctx.col) {
            ctx.col -= leaf.noc;
            if (ctx.last_line_col) |*llc| llc.* -|= leaf.noc;
            return KEEP_WALKING;
        }
        if (ctx.out_of_memory) return STOP;

        var iter = code_point.Iterator{ .bytes = leaf.buf };
        while (iter.next()) |cp| {
            if (ctx.last_line_col) |limit| if (iter.i >= limit + 1) break;
            if (iter.i - 1 >= ctx.col) {
                ctx.list.appendSlice(leaf.buf[cp.offset .. cp.offset + cp.len]) catch {
                    ctx.out_of_memory = true;
                    return STOP;
                };
            }
        }

        ctx.col -|= leaf.noc;
        if (ctx.last_line_col) |*llc| llc.* -|= leaf.noc;
        if (leaf.eol and ctx.last_line_col == null) {
            ctx.list.append('\n') catch {
                ctx.out_of_memory = true;
                return STOP;
            };
        }

        if (leaf.eol) {
            if (ctx.col > 0) ctx.out_of_bounds = true;
            return STOP;
        }
        return KEEP_WALKING;
    }
};

pub fn getRange(node: RcNode, start: EditPoint, end: ?EditPoint, buf: []u8) []const u8 {
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

        const root = try Node.fromString(idc_if_it_leaks, content_arena.allocator(), "const a = 10;");
        const r1 = try insertChars(root, idc_if_it_leaks, content_arena.allocator(), ";", .{ .line = 0, .col = 12 });
        const r2 = try insertChars(r1.node, idc_if_it_leaks, content_arena.allocator(), "/", .{ .line = 0, .col = 13 });
        const r3 = try insertChars(r2.node, idc_if_it_leaks, content_arena.allocator(), "/", .{ .line = 0, .col = 14 });

        try eqStr("const a = 10;//;", try r3.node.value.toString(idc_if_it_leaks, .lf));
        try eqStr("//;", getRange(r3.node, .{ .line = 0, .col = 13 }, null, &buf));
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

        const root = try Node.fromString(idc_if_it_leaks, content_arena.allocator(), "const num = 10;");
        const r1 = try insertChars(root, idc_if_it_leaks, content_arena.allocator(), "X", .{ .line = 0, .col = 6 });

        try eqStr("const Xnum = 10;", try r1.node.value.toString(idc_if_it_leaks, .lf));
        try eqStr("Xnum", getRange(r1.node, .{ .line = 0, .col = 6 }, .{ .line = 0, .col = 10 }, &buf));
    }

    // end col out of bounds
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 6 }, 1024);
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 8 }, 1024);
    try testGetRange("hello\nworld", "world", .{ .line = 1, .col = 0 }, .{ .line = 1, .col = 1000 }, 1024);
}

fn testGetRange(source: []const u8, expected_str: []const u8, start: EditPoint, end: ?EditPoint, comptime buf_size: usize) !void {
    var content_arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer content_arena.deinit();
    var buf: [buf_size]u8 = undefined;
    const root = try Node.fromString(testing_allocator, content_arena.allocator(), source);
    defer freeRcNode(testing_allocator, root);
    const result = getRange(root, start, end, &buf);
    try eqStr(expected_str, result);
}

fn testGetRangeNoEnd(source: []const u8, expected_str: []const u8, start: EditPoint, comptime buf_size: usize) !void {
    try testGetRange(source, expected_str, start, null, buf_size);
}

////////////////////////////////////////////////////////////////////////////////////////////// getLineAlloc

const GetLineAllocCtx = struct {
    list: ArrayList(u8),

    fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkError!WalkResult {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        try ctx.list.appendSlice(leaf.buf);
        if (leaf.eol) return STOP;
        return KEEP_WALKING;
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
    const root = try Node.fromString(idc_if_it_leaks, content_arena.allocator(), "hello\nworld");
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
                else => return STOP,
            }
        }

        if (leaf.eol) return STOP;
        return KEEP_WALKING;
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
        if (leaf.eol) return STOP;
        return KEEP_WALKING;
    }
};

pub fn getNumOfCharsInLine(node: RcNode, line: usize) usize {
    var ctx: GetNumOfCharsInLineCtx = .{};
    _ = walkFromLineBegin(std.heap.page_allocator, node, line, GetNumOfCharsInLineCtx.walker, &ctx) catch unreachable;
    return ctx.result;
}

test getNumOfCharsInLine {
    var content_arena = std.heap.ArenaAllocator.init(idc_if_it_leaks);
    const root = try Node.fromString(idc_if_it_leaks, content_arena.allocator(), "hello\nsuper nova");
    try eq(5, getNumOfCharsInLine(root, 0));
    try eq(10, getNumOfCharsInLine(root, 1));
}

////////////////////////////////////////////////////////////////////////////////////////////// Iterate character by character

const CHARACTER_ITERATOR_MAX_DEPTH = 32;
const BranchSide = enum { left, right };
const CharacterForwardIteratorError = error{ RootTooDeep, OffsetOutOfBounds };

pub const CharacterForwardIterator = struct {
    branches: [CHARACTER_ITERATOR_MAX_DEPTH]*const Node = undefined,
    branch_sides: [CHARACTER_ITERATOR_MAX_DEPTH]BranchSide = undefined,
    branches_len: usize = 0,

    leaf: ?*const Node = null,
    leaf_byte_offset: u32 = 0,

    pub fn init(root: *const Node, offset: u32) CharacterForwardIteratorError!CharacterForwardIterator {
        const root_weights = root.weights();
        if (root_weights.depth > CHARACTER_ITERATOR_MAX_DEPTH) return error.RootTooDeep;
        if (offset > root_weights.len) return error.OffsetOutOfBounds;

        var self = CharacterForwardIterator{};

        switch (root.*) {
            .branch => self.traverseOffset(root, offset),
            .leaf => {
                self.leaf = root;
                self.leaf_byte_offset = offset;
            },
        }

        return self;
    }

    fn traverseOffset(self: *@This(), node: *const Node, offset: u32) void {
        switch (node.*) {
            .branch => |*branch| {
                const left_len = branch.left.value.weights().len;
                const pick_left = left_len > offset;
                const branch_side = if (pick_left) BranchSide.left else BranchSide.right;

                self.branches[self.branches_len] = node;
                self.branch_sides[self.branches_len] = branch_side;
                self.branches_len += 1;

                const child = switch (branch_side) {
                    .left => branch.left.value,
                    .right => branch.right.value,
                };
                const new_offset = switch (branch_side) {
                    .left => offset,
                    .right => offset - left_len,
                };
                self.traverseOffset(child, new_offset);
            },

            .leaf => {
                self.leaf = node;
                self.leaf_byte_offset = offset;
            },
        }
    }

    pub fn next(self: *@This()) ?u21 {
        if (self.leaf == null) {
            if (self.branches_len == 0) return null;

            switch (self.getLatestBranchSide()) {
                .left => self.flipLatestBranchToRightSide(),
                .right => {
                    if (self.branches_len == 1) return null;
                    self.branches_len -= 1;
                    return self.next();
                },
            }
        }

        const result = self.nextCharInLeaf();
        if (result.exhausted) {
            self.leaf = null;
            self.leaf_byte_offset = 0;
        }
        return result.code_point;
    }

    fn nextCharInLeaf(self: *@This()) NextCharInLeafResult {
        assert(self.leaf != null);
        assert(self.leaf.?.* == .leaf);

        if (self.leaf) |leaf_node| {
            const leaf = leaf_node.leaf;

            var iter = code_point.Iterator{ .bytes = leaf.buf, .i = self.leaf_byte_offset };
            if (iter.next()) |cp| {
                self.leaf_byte_offset += cp.len;
                return NextCharInLeafResult{
                    .exhausted = !leaf.eol and self.leaf_byte_offset >= leaf.buf.len,
                    .code_point = cp.code,
                };
            }

            if (leaf_node.leaf.eol) return NextCharInLeafResult{ .exhausted = true, .code_point = '\n' };
        }

        return NextCharInLeafResult{ .exhausted = true, .code_point = null };
    }

    fn flipLatestBranchToRightSide(self: *@This()) void {
        self.branch_sides[self.branches_len - 1] = .right;
        const latest_branch = self.getLatestBranch();
        switch (latest_branch.branch.right.value.*) {
            .leaf => self.setLeaf(latest_branch.branch.right.value),
            .branch => {
                self.appendBranch(latest_branch.branch.right.value);
                self.traverseLatestBranchLeftSide();
            },
        }
    }

    fn traverseLatestBranchLeftSide(self: *@This()) void {
        const latest_branch = self.getLatestBranch();
        switch (latest_branch.branch.left.value.*) {
            .leaf => self.setLeaf(latest_branch.branch.left.value),
            .branch => {
                self.appendBranch(latest_branch.branch.left.value);
                self.traverseLatestBranchLeftSide();
            },
        }
    }

    fn setLeaf(self: *@This(), node: *const Node) void {
        self.leaf = node;
        self.leaf_byte_offset = 0;
    }

    fn appendBranch(self: *@This(), node: *const Node) void {
        self.branches[self.branches_len] = node;
        self.branch_sides[self.branches_len] = .left;
        self.branches_len += 1;
    }

    const NextCharInLeafResult = struct {
        code_point: ?u21 = null,
        exhausted: bool = false,
    };

    fn getLatestBranch(self: *const @This()) *const Node {
        return self.branches[self.branches_len - 1];
    }

    fn getLatestBranchSide(self: *const @This()) BranchSide {
        return self.branch_sides[self.branches_len - 1];
    }
};

test CharacterForwardIterator {
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    {
        const root = try Node.fromString(arena.allocator(), arena.allocator(), "");
        try eq(true, root.value.* == .leaf);
        try eqStr(
            \\1 B| ``
        , try debugStr(arena.allocator(), root));
        try testCharacterForwardIterator(root.value, "", 0);
    }
    {
        const root = try Node.fromString(arena.allocator(), arena.allocator(), "hello");
        try eq(true, root.value.* == .leaf);
        try eqStr(
            \\1 B| `hello`
        , try debugStr(arena.allocator(), root));
        try testCharacterForwardIterator(root.value, "ello", 1);
        try testCharacterForwardIterator(root.value, "llo", 2);
        try testCharacterForwardIterator(root.value, "o", 4);
        try testCharacterForwardIterator(root.value, "", 5);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root.value, 6));
    }
    {
        const root = try Node.fromString(arena.allocator(), arena.allocator(), "hello\nworld");
        try eqStr(
            \\2 2/11/10
            \\  1 B| `hello` |E
            \\  1 B| `world`
        , try debugStr(arena.allocator(), root));
        try testCharacterForwardIterator(root.value, "hello\nworld", 0);
        try testCharacterForwardIterator(root.value, "ello\nworld", 1);
        try testCharacterForwardIterator(root.value, "llo\nworld", 2);
        try testCharacterForwardIterator(root.value, "lo\nworld", 3);
        try testCharacterForwardIterator(root.value, "o\nworld", 4);
        try testCharacterForwardIterator(root.value, "\nworld", 5);
        try testCharacterForwardIterator(root.value, "world", 6);
        try testCharacterForwardIterator(root.value, "orld", 7);
        try testCharacterForwardIterator(root.value, "rld", 8);
        try testCharacterForwardIterator(root.value, "ld", 9);
        try testCharacterForwardIterator(root.value, "d", 10);
        try testCharacterForwardIterator(root.value, "", 11);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root.value, 12));
    }

    { // works with right-skewed tree
        const roots = try insertCharOneAfterAnother(arena.allocator(), arena.allocator(), "hello\nworld", false);
        const root = roots.items[roots.items.len - 1].value;
        try eqStr(
            \\11 2/11/10
            \\  1 B| `h` Rc:10
            \\  10 1/10/9
            \\    1 `e` Rc:9
            \\    9 1/9/8
            \\      1 `l` Rc:8
            \\      8 1/8/7
            \\        1 `l` Rc:7
            \\        7 1/7/6
            \\          1 `o` Rc:6
            \\          6 1/6/5
            \\            1 `` |E Rc:6
            \\            5 1/5/5
            \\              1 B| `w` Rc:4
            \\              4 0/4/4
            \\                1 `o` Rc:3
            \\                3 0/3/3
            \\                  1 `r` Rc:2
            \\                  2 0/2/2
            \\                    1 `l`
            \\                    1 `d`
        , try debugStr(arena.allocator(), roots.items[roots.items.len - 1]));
        try testCharacterForwardIterator(root, "hello\nworld", 0);
        try testCharacterForwardIterator(root, "ello\nworld", 1);
        try testCharacterForwardIterator(root, "llo\nworld", 2);
        try testCharacterForwardIterator(root, "lo\nworld", 3);
        try testCharacterForwardIterator(root, "o\nworld", 4);
        try testCharacterForwardIterator(root, "\nworld", 5);
        try testCharacterForwardIterator(root, "world", 6);
        try testCharacterForwardIterator(root, "orld", 7);
        try testCharacterForwardIterator(root, "rld", 8);
        try testCharacterForwardIterator(root, "ld", 9);
        try testCharacterForwardIterator(root, "d", 10);
        try testCharacterForwardIterator(root, "", 11);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root, 12));
    }
    { // works with left-skewed tree
        const roots = try insertCharOneAfterAnotherAtTheBeginning(arena.allocator(), arena.allocator(), "hello\nworld", null);
        const root = roots.items[roots.items.len - 1].value;
        try eqStr(
            \\11 2/11/10
            \\  10 2/10/9
            \\    9 2/9/8
            \\      8 2/8/7
            \\        7 2/7/6
            \\          6 1/6/5
            \\            5 1/5/5
            \\              4 1/4/4
            \\                3 1/3/3
            \\                  2 1/2/2
            \\                    1 B| `h`
            \\                    1 `e`
            \\                  1 `l` Rc:2
            \\                1 `l` Rc:3
            \\              1 `o` Rc:4
            \\            1 `` |E Rc:5
            \\          1 B| `w` Rc:6
            \\        1 `o` Rc:7
            \\      1 `r` Rc:8
            \\    1 `l` Rc:9
            \\  1 `d` Rc:10
        , try debugStr(arena.allocator(), roots.items[roots.items.len - 1]));
        try testCharacterForwardIterator(root, "hello\nworld", 0);
        try testCharacterForwardIterator(root, "ello\nworld", 1);
        try testCharacterForwardIterator(root, "llo\nworld", 2);
        try testCharacterForwardIterator(root, "lo\nworld", 3);
        try testCharacterForwardIterator(root, "o\nworld", 4);
        try testCharacterForwardIterator(root, "\nworld", 5);
        try testCharacterForwardIterator(root, "world", 6);
        try testCharacterForwardIterator(root, "orld", 7);
        try testCharacterForwardIterator(root, "rld", 8);
        try testCharacterForwardIterator(root, "ld", 9);
        try testCharacterForwardIterator(root, "d", 10);
        try testCharacterForwardIterator(root, "", 11);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root, 12));
    }
    { // works with whatever this is
        const roots_a = try insertCharOneAfterAnother(arena.allocator(), arena.allocator(), "\nworld", false);
        const roots_b = try insertCharOneAfterAnotherAtTheBeginning(arena.allocator(), arena.allocator(), "hello", roots_a.items[roots_a.items.len - 1]);
        try eqStr(
            \\7 2/11/10
            \\  6 1/6/5
            \\    5 1/5/5
            \\      4 1/4/4
            \\        3 1/3/3
            \\          2 1/2/2
            \\            1 B| `h`
            \\            1 `e`
            \\          1 `l` Rc:2
            \\        1 `l` Rc:3
            \\      1 `o` Rc:4
            \\    1 `` |E Rc:5
            \\  5 1/5/5 Rc:6
            \\    1 B| `w` Rc:4
            \\    4 0/4/4
            \\      1 `o` Rc:3
            \\      3 0/3/3
            \\        1 `r` Rc:2
            \\        2 0/2/2
            \\          1 `l`
            \\          1 `d`
        , try debugStr(arena.allocator(), roots_b.items[roots_b.items.len - 1]));
        const root = roots_b.items[roots_b.items.len - 1].value;
        try testCharacterForwardIterator(root, "hello\nworld", 0);
        try testCharacterForwardIterator(root, "ello\nworld", 1);
        try testCharacterForwardIterator(root, "llo\nworld", 2);
        try testCharacterForwardIterator(root, "lo\nworld", 3);
        try testCharacterForwardIterator(root, "o\nworld", 4);
        try testCharacterForwardIterator(root, "\nworld", 5);
        try testCharacterForwardIterator(root, "world", 6);
        try testCharacterForwardIterator(root, "orld", 7);
        try testCharacterForwardIterator(root, "rld", 8);
        try testCharacterForwardIterator(root, "ld", 9);
        try testCharacterForwardIterator(root, "d", 10);
        try testCharacterForwardIterator(root, "", 11);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root, 12));
    }
    { // works with balanced tree
        const roots = try insertCharOneAfterAnother(arena.allocator(), arena.allocator(), "hello\nworld", true);
        const root = roots.items[roots.items.len - 1].value;
        try eqStr(
            \\6 2/11/10 Rc:0
            \\  3 1/3/3 Rc:6
            \\    2 1/2/2 Rc:3
            \\      1 B| `h` Rc:3
            \\      1 `e` Rc:2
            \\    1 `l` Rc:3
            \\  5 1/8/7 Rc:0
            \\    3 1/4/3 Rc:2
            \\      2 0/2/2 Rc:5
            \\        1 `l` Rc:2
            \\        1 `o`
            \\      2 1/2/1 Rc:2
            \\        1 `` |E Rc:4
            \\        1 B| `w` Rc:2
            \\    4 0/4/4
            \\      1 `o` Rc:3
            \\      3 0/3/3
            \\        1 `r` Rc:2
            \\        2 0/2/2
            \\          1 `l`
            \\          1 `d`
        , try debugStr(arena.allocator(), roots.items[roots.items.len - 1]));
        try testCharacterForwardIterator(root, "hello\nworld", 0);
        try testCharacterForwardIterator(root, "ello\nworld", 1);
        try testCharacterForwardIterator(root, "llo\nworld", 2);
        try testCharacterForwardIterator(root, "lo\nworld", 3);
        try testCharacterForwardIterator(root, "o\nworld", 4);
        try testCharacterForwardIterator(root, "\nworld", 5);
        try testCharacterForwardIterator(root, "world", 6);
        try testCharacterForwardIterator(root, "orld", 7);
        try testCharacterForwardIterator(root, "rld", 8);
        try testCharacterForwardIterator(root, "ld", 9);
        try testCharacterForwardIterator(root, "d", 10);
        try testCharacterForwardIterator(root, "", 11);
        try shouldErr(error.OffsetOutOfBounds, CharacterForwardIterator.init(root, 12));
    }
}

fn testCharacterForwardIterator(root: *Node, expected: []const u8, offset: u32) !void {
    var iter = try CharacterForwardIterator.init(root, offset);
    var cp_iter = code_point.Iterator{ .bytes = expected };
    var count: usize = 0;
    while (true) {
        defer count += 1;

        const iter_result = iter.next();
        const cp_iter_result = cp_iter.next();

        if (iter_result == null) {
            errdefer {
                const print_iter = CharacterForwardIterator.init(root, offset) catch unreachable;
                std.debug.print("failed at count: {d}\n", .{count});
                std.debug.print("===============================\n", .{});
                for (0..print_iter.branches_len) |i| {
                    const branch = iter.branches[i];
                    std.debug.print("depth: {d} | '{s}'\n", .{
                        branch.weights().depth,
                        Node.toString(branch, idc_if_it_leaks, .lf) catch unreachable,
                    });
                }
                std.debug.print("===============================\n", .{});
            }
            try eq(null, cp_iter_result);
            return;
        }

        // std.debug.print("iter_result: '{c}'\n", .{@as(u8, @intCast(iter_result.?))});
        try eq(cp_iter_result.?.code, iter_result.?);
    }
}

fn insertCharOneAfterAnotherAtTheBeginning(a: Allocator, content_allocator: Allocator, str: []const u8, may_root: ?RcNode) !ArrayList(RcNode) {
    var list = try ArrayList(RcNode).initCapacity(a, str.len + 1);
    var node = if (may_root) |root| root else try Node.fromString(a, content_allocator, "");
    try list.append(node);

    var i: usize = str.len;
    while (i > 0) {
        i -= 1;
        const result = try insertChars(node, a, content_allocator, &.{str[i]}, .{ .line = 0, .col = 0 });
        node = result.node;
        try list.append(result.node);
    }

    return list;
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

pub const EditPoint = struct {
    line: usize,
    col: usize,

    pub fn cmp(_: void, a: EditPoint, b: EditPoint) bool {
        if (a.line < b.line) return true;
        if (a.line == b.line and a.col < b.col) return true;
        return false;
    }
};

pub const EditRange = struct {
    start: EditPoint,
    end: EditPoint,

    pub fn isEmpty(self: *const @This()) bool {
        return self.start.line == self.end.line and self.start.col == self.end.col;
    }

    pub fn cmp(_: void, a: EditRange, b: EditRange) bool {
        assert(std.sort.isSorted(EditPoint, &.{ a.start, a.end }, {}, EditPoint.cmp));
        assert(std.sort.isSorted(EditPoint, &.{ b.start, b.end }, {}, EditPoint.cmp));

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

//////////////////////////////////////////////////////////////////////////////////////////////
