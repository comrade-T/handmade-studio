const std = @import("std");
const code_point = @import("code_point");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;
const idc_if_it_leaks = std.heap.page_allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

/// Represents the result of a walk operation on a Node.
/// This walk operation never mutates the current Node and may create new Nodes.
const WalkMutResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    replace: ?*const Node = null,
    removed: bool = false,

    const keep_walking = WalkMutResult{ .keep_walking = true };
    const stop = WalkMutResult{ .keep_walking = false };
    const found = WalkMutResult{ .found = true };
    const removed = WalkMutResult{ .removed = true };

    fn merge(a: Allocator, b: *const Branch, left: WalkMutResult, right: WalkMutResult) WalkMutResult {
        var result = WalkMutResult{};
        result.err = if (left.err) |_| left.err else right.err;
        result.keep_walking = left.keep_walking and right.keep_walking;
        result.found = left.found or right.found;
        result.removed = left.removed and right.removed;
        if (!result.removed) result.replace = _getReplacement(a, b, left, right) catch |err| return .{ .err = err };
        return result;
    }
    fn _getReplacement(a: Allocator, b: *const Branch, left: WalkMutResult, right: WalkMutResult) !?*const Node {
        const left_replace = if (left.replace) |p| p else b.left;
        const right_replace = if (right.replace) |p| p else b.right;
        if (left.removed) return right_replace;
        if (right.removed) return left_replace;
        if (left.replace == null and right.replace == null) return null;
        return try Node.new(a, left_replace, right_replace);
    }

    test merge {
        const a = idc_if_it_leaks;
        const left = try Leaf.new(a, "one", true, false);
        const right = try Leaf.new(a, "_two", false, true);
        const node = try Node.new(a, left, right);
        {
            const left_result = WalkMutResult.keep_walking;
            const right_replace = try Leaf.new(a, "_2", true, false);
            const right_result = WalkMutResult{ .found = true, .replace = right_replace };
            const merge_result = WalkMutResult.merge(a, &node.branch, left_result, right_result);
            try eq(left, merge_result.replace.?.branch.left);
            try eq(right_replace, merge_result.replace.?.branch.right);
        }
        {
            const merge_result = WalkMutResult.merge(a, &node.branch, WalkMutResult.removed, WalkMutResult.found);
            try eq(right, merge_result.replace.?);
        }
        {
            const merge_result = WalkMutResult.merge(a, &node.branch, WalkMutResult.keep_walking, WalkMutResult.removed);
            try eq(left, merge_result.replace.?);
        }
        {
            const merge_result = WalkMutResult.merge(a, &node.branch, WalkMutResult.removed, WalkMutResult.removed);
            try eq(null, merge_result.replace);
            try eq(true, merge_result.removed);
        }
    }
};

/// Represents the result of a walk operation on a Node.
/// This walk operation should never mutate the current Node or create a new Node.
const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?anyerror = null,

    const keep_walking = WalkResult{ .keep_walking = true };
    const stop = WalkResult{ .keep_walking = false };
    const found = WalkResult{ .found = true };

    /// Produce a merged walk result from `self` and another WalkResult.
    fn merge(self: WalkResult, right: WalkResult) WalkResult {
        return WalkResult{
            .err = if (self.err) |_| self.err else right.err,
            .keep_walking = self.keep_walking and right.keep_walking,
            .found = self.found or right.found,
        };
    }
    test merge {
        try eqDeep(WalkResult.found, merge(WalkResult.found, WalkResult.keep_walking));
        try eqDeep(WalkResult.keep_walking, merge(WalkResult.keep_walking, WalkResult.keep_walking));
        try eqDeep(WalkResult.stop, merge(WalkResult.stop, WalkResult.keep_walking));
    }
};

/// Primary data structure to manage an editable text buffer.
/// Can either be a Branch or a Leaf.
pub const Node = union(enum) {
    branch: Branch,
    leaf: Leaf,

    /// Create a new Branch Node, given a `left` Node and a `right` Node.
    fn new(a: Allocator, left: *const Node, right: *const Node) !*const Node {
        const node = try a.create(Node);
        var w = Weights{};
        w.add(left.weights());
        w.add(right.weights());
        w.depth += 1;
        node.* = .{ .branch = .{ .left = left, .right = right, .weights = w } };
        return node;
    }

    ///////////////////////////// Load

    pub fn fromString(a: Allocator, source: []const u8, first_bol: bool) !*const Node {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, stream.reader(), source.len, first_bol);
    }
    test fromString {
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", false);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "hello", .noc = 5 }, root.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world", .noc = 5 }, root.branch.right.leaf);
        }
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", true);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "hello", .noc = 5 }, root.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world", .noc = 5 }, root.branch.right.leaf);
        }
    }

    /// Use `reader` to read into a buffer, create leaves by new line from that buffer,
    /// then recursively merge those leaves.
    fn fromReader(a: Allocator, reader: anytype, buffer_size: usize, first_bol: bool) !*const Node {
        const buf = try a.alloc(u8, buffer_size);

        const read_size = try reader.read(buf);
        if (read_size != buffer_size) return error.BufferUnderrun;

        const final_read = try reader.read(buf);
        if (final_read != 0) @panic("unexpected data in final read");

        var leaves = try createLeavesByNewLine(a, buf);
        leaves[0].leaf.bol = first_bol;
        return try mergeLeaves(a, leaves);
    }

    fn createLeavesByNewLine(a: std.mem.Allocator, buf: []const u8) ![]Node {
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
                leaves[cur_leaf] = .{ .leaf = .{ .buf = line, .noc = getNumOfChars(line), .bol = true, .eol = true } };
                cur_leaf += 1;
                b = i + 1;
            }
        }

        const rest = buf[b..];
        leaves[cur_leaf] = .{ .leaf = .{ .buf = rest, .noc = getNumOfChars(rest), .bol = true, .eol = false } };

        leaves[0].leaf.bol = false; // always make first Leaf NOT a .bol

        if (leaves.len != cur_leaf + 1) return error.Unexpected;
        return leaves;
    }
    test createLeavesByNewLine {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "");
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "", .noc = 0 }, leaves[0].leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "hello\nworld");
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "hello", .noc = 5 }, leaves[0].leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "world", .noc = 5 }, leaves[1].leaf);
        }
    }

    /// Recursively create and return Nodes given a slice of Leaves.
    fn mergeLeaves(a: Allocator, leaves: []const Node) !*const Node {
        if (leaves.len == 1) return &leaves[0];
        if (leaves.len == 2) return Node.new(a, &leaves[0], &leaves[1]);
        const mid = leaves.len / 2;
        return Node.new(a, try mergeLeaves(a, leaves[0..mid]), try mergeLeaves(a, leaves[mid..]));
    }
    test mergeLeaves {
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "one\ntwo\nthree\nfour");
            const root = try mergeLeaves(idc_if_it_leaks, leaves);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "one", .noc = 3 }, root.branch.left.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "two", .noc = 3 }, root.branch.left.branch.right.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = true, .buf = "three", .noc = 5 }, root.branch.right.branch.left.leaf);
            try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "four", .noc = 4 }, root.branch.right.branch.right.leaf);
        }
    }

    ///////////////////////////// Get Index from Line & Col

    // pub fn getByteOffsetFromLineAndCol(self: *const Node, line: u32, col: u32) !void {
    //     const GetByteOffsetFromLineAndColCtx = struct {
    //         target_line: u32,
    //         target_col: u32,
    //         current_line: u32 = 0,
    //         current_col: u32 = 0,
    //         should_stop: bool = false,
    //
    //         fn walk(cx: *@This(), node: *const Node) WalkResult {
    //             if (cx.should_stop) return WalkResult.stop;
    //             if (cx.current_line > cx.target_line) unreachable;
    //             switch (node.*) {
    //                 .branch => |branch| {
    //                     if (cx.current_line < cx.target_line) {
    //                         const left_line_end = cx.current_line + branch.left.weights().bols;
    //                         var left_result = WalkResult.keep_walking;
    //                         if (cx.target_line == cx.current_line or cx.target_line < left_line_end) left_result = cx.walk(branch.left);
    //                         cx.current_line = left_line_end;
    //                         const right_result = cx.walk(branch.right);
    //                         return WalkResult.merge(left_result, right_result);
    //                     }
    //
    //                     const left_col_end = cx.current_line + branch.left.weights().len; // TODO: we need num_of_chars, not len
    //
    //                     var left_result = WalkResult.keep_walking;
    //                     if (cx.target_col < left_col_end) left_result = cx.walk(branch.left);
    //                     cx.current_col = left_col_end;
    //                     const right_result = cx.walk(branch.right);
    //                     return WalkResult.merge(left_result, right_result);
    //                 },
    //                 .leaf => |leaf| return cx.walker(&leaf),
    //             }
    //         }
    //
    //         fn walker() WalkResult {
    //             // TODO:
    //         }
    //     };
    //
    //     var ctx = GetByteOffsetFromLineAndColCtx{ .target_line = line, .target_col = col };
    //     const walk_result = ctx.walk(self);
    // }
    //
    // test getByteOffsetFromLineAndCol {
    //     const a = idc_if_it_leaks;
    //     {
    //         const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
    //         try eq(0, root.getByteOffsetFromLineAndCol(0, 0));
    //     }
    // }

    ///////////////////////////// Get Content

    // Walk through entire tree, append each Leaf content to ArrayList(u8), then return that ArrayList(u8).
    pub fn getDocument(self: *const Node, a: Allocator) !ArrayList(u8) {
        const GetDocumentCtx = struct {
            result_list: *ArrayList(u8),

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                switch (node.*) {
                    .branch => |branch| {
                        const left_result = cx.walk(branch.left);
                        const right_result = cx.walk(branch.right);
                        return WalkResult.merge(left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
                cx.result_list.appendSlice(leaf.buf) catch |err| return .{ .err = err };
                if (leaf.eol) cx.result_list.append('\n') catch |err| return .{ .err = err };
                return WalkResult.keep_walking;
            }
        };

        var result_list = try ArrayList(u8).initCapacity(a, self.weights().len);
        var ctx = GetDocumentCtx{ .result_list = &result_list };
        const walk_result = ctx.walk(self);
        if (walk_result.err) |err| {
            result_list.deinit();
            return err;
        }
        return result_list;
    }

    test getDocument {
        const a = idc_if_it_leaks;
        {
            const source = "";
            const root = try Node.fromString(a, source, true);
            const result = try root.getDocument(a);
            try eqStr(source, result.items);
        }
        {
            const source = "one\ntwo\nthree\nfour";
            const root = try Node.fromString(a, source, true);
            const result = try root.getDocument(a);
            try eqStr(source, result.items);
        }
    }

    pub fn getLine(self: *const Node, a: Allocator, linenr: u32) !ArrayList(u8) {
        const GetLineCtx = struct {
            target_linenr: u32,
            current_linenr: u32 = 0,
            result_list: *ArrayList(u8),
            should_stop: bool = false,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.should_stop) return WalkResult.stop;
                switch (node.*) {
                    .branch => |branch| {
                        const left_end = cx.current_linenr + branch.left.weights().bols;
                        var left_result = WalkResult.keep_walking;
                        if (cx.target_linenr == cx.current_linenr or cx.target_linenr < left_end) left_result = cx.walk(branch.left);
                        cx.current_linenr = left_end;
                        const right_result = cx.walk(branch.right);
                        return WalkResult.merge(left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
                cx.result_list.appendSlice(leaf.buf) catch |err| return .{ .err = err };
                if (leaf.eol) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (linenr + 1 > self.weights().bols) return error.NotFound;
        var result_list = ArrayList(u8).init(a);
        var ctx = GetLineCtx{ .target_linenr = linenr, .result_list = &result_list };

        const walk_result = ctx.walk(self);
        if (walk_result.err) |err| {
            result_list.deinit();
            return err;
        }
        return result_list;
    }

    test getLine {
        const a = idc_if_it_leaks;

        { // can get line that contained in 1 single Leaf
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            {
                const line = try root.getLine(a, 0);
                try eqStr("one", line.items);
            }
            {
                const line = try root.getLine(a, 1);
                try eqStr("two", line.items);
            }
            {
                const line = try root.getLine(a, 2);
                try eqStr("three", line.items);
            }
            {
                const line = try root.getLine(a, 3);
                try eqStr("four", line.items);
            }
        }

        // can get line that spans across multiple Leaves
        {
            const old = try Node.fromString(a, "one\ntwo\nthree", true);
            const root = try old.insertChars(a, 3, "_1");
            {
                const line = try root.getLine(a, 0);
                try eqStr("one_1", line.items);
            }
            {
                const line = try root.getLine(a, 1);
                try eqStr("two", line.items);
            }
            {
                const line = try root.getLine(a, 2);
                try eqStr("three", line.items);
            }
            try shouldErr(error.NotFound, root.getLine(a, 3));
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
                {
                    const line = try root.getLine(a, 0);
                    try eqStr("one_two_three", line.items);
                }
                {
                    const line = try root.getLine(a, 1);
                    try eqStr("four", line.items);
                }
            }
            {
                const root = try Node.new(a, four, one_two_three);
                {
                    const line = try root.getLine(a, 0);
                    try eqStr("four", line.items);
                }
                {
                    const line = try root.getLine(a, 1);
                    try eqStr("one_two_three", line.items);
                }
            }
        }
    }

    ///////////////////////////// Balancing

    const MAX_IMBALANCE = 1;

    fn calculateBalanceFactor(left: *const Node, right: *const Node) i64 {
        var balance_factor: i64 = @intCast(left.weights().depth);
        balance_factor -= right.weights().depth;
        return balance_factor;
    }

    fn balance(self: *const Node, a: Allocator) !*const Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |branch| {
                var result: *const Node = undefined;
                defer if (result != self) a.destroy(self);

                const left = try branch.left.balance(a);
                const right = try branch.right.balance(a);
                const balance_factor = calculateBalanceFactor(left, right);

                if (@abs(balance_factor) > MAX_IMBALANCE) {
                    if (balance_factor < 0) {
                        const right_balance_factor = calculateBalanceFactor(right.branch.left, right.branch.right);
                        if (right_balance_factor <= 0) {
                            const this = if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
                            result = try this.rotateLeft(a);
                        } else {
                            const new_right = try right.rotateRight(a);
                            const this = try Node.new(a, left, new_right);
                            result = try this.rotateLeft(a);
                        }
                    } else {
                        const left_balance_factor = calculateBalanceFactor(left.branch.left, left.branch.right);
                        if (left_balance_factor >= 0) {
                            const this = if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
                            result = try this.rotateRight(a);
                        } else {
                            const new_left = try left.rotateLeft(a);
                            const this = try Node.new(a, new_left, right);
                            result = try this.rotateRight(a);
                        }
                    }
                } else {
                    result = if (branch.left != left or branch.right != right) try Node.new(a, left, right) else self;
                }

                const should_balance_again = result.* == .branch and @abs(calculateBalanceFactor(result.branch.left, result.branch.right)) > MAX_IMBALANCE;
                if (should_balance_again) result = try result.balance(a);

                return result;
            },
        }
    }
    test balance {
        const a = idc_if_it_leaks;
        {
            const root = try __inputCharsOneAfterAnother(a, "abcde");
            const root_debug_str =
                \\5 0/5/5
                \\  1 `a`
                \\  4 0/4/4
                \\    1 `b`
                \\    3 0/3/3
                \\      1 `c`
                \\      2 0/2/2
                \\        1 `d`
                \\        1 `e`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            const balanced_root = try root.balance(a);
            const balanced_root_debug_str =
                \\4 0/5/5
                \\  3 0/3/3
                \\    1 `a`
                \\    2 0/2/2
                \\      1 `b`
                \\      1 `c`
                \\  2 0/2/2
                \\    1 `d`
                \\    1 `e`
            ;
            try eqStr(balanced_root_debug_str, try balanced_root.debugPrint());
        }
        // {
        //     const source = "abcdefghijklmnopqrstuvwxyz1234567890";
        //     const root = try __inputCharsAndRebalanceOneAfterAnother(a, source, 100);
        //     const balanced_root = try root.balance(a);
        //     try eqStr("doesn't matter, just checking the output since it's too large", try balanced_root.debugPrint());
        // }
    }
    fn __inputCharsOneAfterAnother(a: Allocator, chars: []const u8) !*const Node {
        var root = try Node.fromString(a, "", false);
        for (0..chars.len) |i| {
            root = try root.insertChars(a, root.weights().len, chars[i .. i + 1]);
            // if (i == chars.len - 1) std.debug.print("finished __inputCharsOneAfterAnother i == {d}\n", .{i});
        }
        return root;
    }
    fn __inputCharsAndRebalanceOneAfterAnother(a: Allocator, chars: []const u8, multiplier: usize) !*const Node {
        var root = try Node.fromString(a, "", false);
        var count: usize = 0;
        for (0..multiplier) |_| {
            for (0..chars.len) |i| {
                root = try root.insertChars(a, root.weights().len, chars[i .. i + 1]);
                root = try root.balance(a);
                count += 1;
            }
        }
        // std.debug.print("finished __inputCharsAndRebalanceOneAfterAnother count == {d}\n", .{count});
        return root;
    }

    fn rotateRight(self: *const Node, allocator: Allocator) !*const Node {
        const other = self.branch.left;
        defer allocator.destroy(self);
        defer allocator.destroy(other);
        const a = try Node.new(allocator, other.branch.right, self.branch.right);
        const b = try Node.new(allocator, other.branch.left, a);
        return b;
    }
    test rotateRight {
        const a = idc_if_it_leaks;
        {
            const abc = try Node.fromString(a, "ACD", false);
            const abcd = try abc.insertChars(a, 1, "B");
            const root = try abcd.insertChars(a, 1, "a");
            const node_to_rotate = root.branch.right;
            const node_to_rotate_print =
                \\3 0/4/4
                \\  2 0/2/2
                \\    1 `a`
                \\    1 `B`
                \\  1 `CD`
            ;
            try eqStr(node_to_rotate_print, try node_to_rotate.debugPrint());
            const result = try node_to_rotate.rotateRight(a);
            const result_print =
                \\3 0/4/4
                \\  1 `a`
                \\  2 0/3/3
                \\    1 `B`
                \\    1 `CD`
            ;
            try eqStr(result_print, try result.debugPrint());
        }
    }

    fn rotateLeft(self: *const Node, allocator: Allocator) !*const Node {
        const other = self.branch.right;
        defer allocator.destroy(self);
        defer allocator.destroy(other);
        const a = try Node.new(allocator, self.branch.left, other.branch.left);
        const b = try Node.new(allocator, a, other.branch.right);
        return b;
    }
    test rotateLeft {
        const a = idc_if_it_leaks;
        {
            const acd = try Node.fromString(a, "ACD", false);
            const abcd = try acd.insertChars(a, 1, "B");
            const old_root = try abcd.insertChars(a, 4, "E");
            const old_root_print =
                \\4 0/5/5
                \\  1 `A`
                \\  3 0/4/4
                \\    1 `B`
                \\    2 0/3/3
                \\      1 `CD`
                \\      1 `E`
            ;
            try eqStr(old_root_print, try old_root.debugPrint());
            const new_root = try old_root.rotateLeft(a);
            const new_root_print =
                \\3 0/5/5
                \\  2 0/2/2
                \\    1 `A`
                \\    1 `B`
                \\  2 0/3/3
                \\    1 `CD`
                \\    1 `E`
            ;
            try eqStr(new_root_print, try new_root.debugPrint());
        }
    }

    ///////////////////////////// Delete Bytes

    fn deleteBytes(self: *const Node, a: Allocator, start_byte: usize, num_of_bytes_to_delete: usize) !*const Node {
        const DeleteBytesCtx = struct {
            a: Allocator,

            leaves_encountered: usize = 0,
            first_leaf_bol: ?bool = null,

            start_byte: usize,
            num_of_bytes_to_delete: usize,
            end_byte: usize,

            current_index: *usize,
            bytes_deleted: usize = 0,

            fn walk(cx: *@This(), allocator: Allocator, node: *const Node) WalkMutResult {
                if (cx.current_index.* > cx.end_byte + 1) return WalkMutResult.stop;

                switch (node.*) {
                    .branch => |*branch| {
                        const left_end = cx.current_index.* + branch.left.weights().len;

                        const left_result = if (cx.start_byte < left_end)
                            cx.walk(allocator, branch.left)
                        else
                            WalkMutResult.keep_walking;

                        cx.current_index.* = left_end;
                        const right_result = cx.walk(allocator, branch.right);

                        return WalkMutResult.merge(allocator, branch, left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                defer cx.leaves_encountered += 1;

                const leaf_outside_delete_range = cx.current_index.* >= cx.end_byte;
                if (leaf_outside_delete_range) return _amendBol(cx, leaf);

                const start_before_leaf = cx.start_byte <= cx.current_index.*;
                const end_after_leaf = cx.end_byte >= cx.current_index.* + leaf.buf.len - 1;
                const delete_covers_leaf = start_before_leaf and end_after_leaf;
                if (delete_covers_leaf) return _removed(cx, leaf);

                const start_in_leaf = cx.current_index.* <= cx.start_byte;
                const end_in_leaf = cx.current_index.* + leaf.buf.len >= cx.end_byte;
                const leaf_covers_delete = start_in_leaf and end_in_leaf;

                if (leaf_covers_delete) return _trimmedLeftAndTrimmedRight(cx, leaf);
                if (start_in_leaf) return _leftSide(cx, leaf);
                if (end_in_leaf) return _rightSide(cx, leaf);

                unreachable;
            }

            fn _amendBol(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                if (cx.first_leaf_bol) |bol| {
                    const replace = Leaf.new(cx.a, leaf.buf, bol, leaf.eol) catch |err| return .{ .err = err };
                    return WalkMutResult{ .replace = replace };
                }
                return WalkMutResult.stop;
            }

            fn _removed(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                if (cx.leaves_encountered == 0) cx.first_leaf_bol = leaf.bol;
                cx.bytes_deleted += leaf.buf.len;
                return WalkMutResult.removed;
            }

            fn _trimmedLeftAndTrimmedRight(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                const split_index = cx.start_byte - cx.current_index.*;
                const left_side_content = leaf.buf[0..split_index];
                const right_side_content = leaf.buf[split_index + cx.num_of_bytes_to_delete .. leaf.buf.len];

                const left_side_wiped_out = left_side_content.len == 0;
                if (left_side_wiped_out) {
                    const right_side = Leaf.new(cx.a, right_side_content, leaf.bol, leaf.eol) catch |err| return .{ .err = err };
                    return WalkMutResult{ .replace = right_side };
                }

                const right_side_wiped_out = right_side_content.len == 0;
                if (right_side_wiped_out) {
                    const left_side = Leaf.new(cx.a, left_side_content, leaf.bol, leaf.eol) catch |err| return .{ .err = err };
                    return WalkMutResult{ .replace = left_side };
                }

                const left_side = Leaf.new(cx.a, left_side_content, leaf.bol, false) catch |err| return .{ .err = err };
                const right_side = Leaf.new(cx.a, right_side_content, false, leaf.eol) catch |err| return .{ .err = err };
                const replace = Node.new(cx.a, left_side, right_side) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = replace };
            }

            fn _leftSide(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                const split_index = cx.start_byte - cx.current_index.*;
                const left_side_content = leaf.buf[0..split_index];
                const left_side = Leaf.new(cx.a, left_side_content, leaf.bol, leaf.eol) catch |err| return .{ .err = err };
                cx.bytes_deleted += leaf.buf.len - left_side_content.len;
                return WalkMutResult{ .replace = left_side };
            }

            fn _rightSide(cx: *@This(), leaf: *const Leaf) WalkMutResult {
                const bytes_left_to_delete = cx.num_of_bytes_to_delete - cx.bytes_deleted;
                const right_side_content = leaf.buf[bytes_left_to_delete..];
                const right_side = Leaf.new(cx.a, right_side_content, leaf.bol, leaf.eol) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = right_side };
            }
        };

        const end_byte = start_byte + num_of_bytes_to_delete;
        if (start_byte > self.weights().len or end_byte > self.weights().len) return error.IndexOutOfBounds;

        var current_index: usize = 0;
        var ctx = DeleteBytesCtx{
            .a = a,
            .current_index = &current_index,
            .num_of_bytes_to_delete = num_of_bytes_to_delete,
            .start_byte = start_byte,
            .end_byte = end_byte,
        };
        const walk_result = ctx.walk(a, self);

        if (walk_result.err) |e| return e;
        return if (walk_result.replace) |replacement| replacement else try Leaf.new(a, "", true, false);
    }

    test deleteBytes {
        const a = idc_if_it_leaks;

        { // Delete operation contained only in 1 single Leaf node, with Leaf as root:
            const abcd = try Leaf.new(a, "ABCD", true, false);
            {
                const new_root = try abcd.deleteBytes(a, 0, 1);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "BCD", .noc = 3 }, new_root.leaf);
            }
            {
                const new_root = try abcd.deleteBytes(a, 0, 2);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "CD", .noc = 2 }, new_root.leaf);
            }
            {
                const new_root = try abcd.deleteBytes(a, 0, 4);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "", .noc = 0 }, new_root.leaf);
            }
            {
                const new_root = try abcd.deleteBytes(a, 1, 1);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "A", .noc = 1 }, new_root.branch.left.leaf);
                try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "CD", .noc = 2 }, new_root.branch.right.leaf);
            }
            {
                const new_root = try abcd.deleteBytes(a, 1, 3);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "A", .noc = 1 }, new_root.leaf);
            }
            {
                const new_root = try abcd.deleteBytes(a, 3, 1);
                try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "ABC", .noc = 3 }, new_root.leaf);
            }
        }

        const one_two = try Node.new(a, try Leaf.new(a, "one", true, false), try Leaf.new(a, "_two", false, false));
        const three_four = try Node.new(a, try Leaf.new(a, "_three", false, false), try Leaf.new(a, "_four", false, true));
        const one_two_three_four = try Node.new(a, one_two, three_four);
        const one_two_three_four_str =
            \\3 1/19/18
            \\  2 1/7/7
            \\    1 B| `one`
            \\    1 `_two`
            \\  2 0/12/11
            \\    1 `_three`
            \\    1 `_four` |E
        ;
        try eqStr(one_two_three_four_str, try one_two_three_four.debugPrint());

        { // Delete operation contained only in 1 single Leaf node, with Branch as root:
            {
                const new_root = try one_two_three_four.deleteBytes(a, 0, 1);
                const new_root_debug_str =
                    \\3 1/18/17
                    \\  2 1/6/6
                    \\    1 B| `ne`
                    \\    1 `_two`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 3, 2);
                const new_root_debug_str =
                    \\3 1/17/16
                    \\  2 1/5/5
                    \\    1 B| `one`
                    \\    1 `wo`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 0, 3);
                const new_root_debug_str =
                    \\3 1/16/15
                    \\  1 B| `_two`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
        }

        { // Delete operation spans across multiple Leaves
            {
                const new_root = try one_two_three_four.deleteBytes(a, 1, 3);
                const new_root_debug_str =
                    \\3 1/16/15
                    \\  2 1/4/4
                    \\    1 B| `o`
                    \\    1 `two`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 1, 4);
                const new_root_debug_str =
                    \\3 1/15/14
                    \\  2 1/3/3
                    \\    1 B| `o`
                    \\    1 `wo`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 1, 6);
                const new_root_debug_str =
                    \\3 1/13/12
                    \\  1 B| `o`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 0, 6);
                const new_root_debug_str =
                    \\2 1/12/11
                    \\  1 B| `_three`
                    \\  1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
        }
    }

    ///////////////////////////// Insert Chars

    const InsertCharsCtx = struct {
        a: Allocator,
        buf: []const u8,
        target_index: usize,
        current_index: usize = 0,

        fn walkToInsert(ctx: *@This(), node: *const Node) WalkMutResult {
            if (ctx.current_index > ctx.target_index) return WalkMutResult.stop;
            switch (node.*) {
                .branch => |*branch| {
                    const left_end = ctx.current_index + branch.left.weights().len;
                    if (ctx.target_index < left_end) {
                        const left_result = ctx.walkToInsert(branch.left);
                        return WalkMutResult{
                            .err = left_result.err,
                            .found = left_result.found,
                            .replace = if (left_result.replace) |replacement|
                                Node.new(ctx.a, replacement, branch.right) catch |e| return WalkMutResult{ .err = e }
                            else
                                null,
                        };
                    }
                    ctx.current_index = left_end;
                    const right_result = ctx.walkToInsert(branch.right);
                    return WalkMutResult{
                        .err = right_result.err,
                        .found = right_result.found,
                        .replace = if (right_result.replace) |replacement|
                            Node.new(ctx.a, branch.left, replacement) catch |e| return WalkMutResult{ .err = e }
                        else
                            null,
                    };
                },
                .leaf => |leaf| return ctx.walker(&leaf),
            }
        }

        fn walker(cx: *@This(), leaf: *const Leaf) WalkMutResult {
            var new_leaves = createLeavesByNewLine(cx.a, cx.buf) catch |err| return .{ .err = err };

            if (leaf.buf.len == 0) {
                new_leaves[0].leaf.bol = leaf.bol;
                const replacement = mergeLeaves(cx.a, new_leaves) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = replacement };
            }

            const insert_at_start = cx.current_index == cx.target_index;
            if (insert_at_start) {
                new_leaves[0].leaf.bol = leaf.bol;
                const left = mergeLeaves(cx.a, new_leaves) catch |err| return .{ .err = err };
                const right = Leaf.new(cx.a, leaf.buf, false, leaf.eol) catch |err| return .{ .err = err };
                const replacement = Node.new(cx.a, left, right) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = replacement };
            }

            const insert_at_end = cx.current_index + leaf.buf.len == cx.target_index;
            if (insert_at_end) {
                new_leaves[new_leaves.len - 1].leaf.eol = leaf.eol;
                const left = Leaf.new(cx.a, leaf.buf, leaf.bol, false) catch |err| return .{ .err = err };
                const right = mergeLeaves(cx.a, new_leaves) catch |err| return .{ .err = err };
                const replacement = Node.new(cx.a, left, right) catch |err| return .{ .err = err };
                return WalkMutResult{ .replace = replacement };
            }

            // insert in middle
            const split_index = cx.target_index - cx.current_index;
            const left_split = leaf.buf[0..split_index];
            const right_split = leaf.buf[split_index..leaf.buf.len];

            const left = mergeLeaves(cx.a, new_leaves) catch |err| return .{ .err = err };
            const right = Leaf.new(cx.a, right_split, false, leaf.eol) catch |err| return .{ .err = err };
            const upper_left = Leaf.new(cx.a, left_split, leaf.bol, false) catch |err| return .{ .err = err };
            const upper_right = Node.new(cx.a, left, right) catch |err| return .{ .err = err };

            const replacement = Node.new(cx.a, upper_left, upper_right) catch |err| return .{ .err = err };
            return WalkMutResult{ .replace = replacement };
        }
    };

    pub fn insertChars(self: *const Node, a: Allocator, target_index: usize, chars: []const u8) !*const Node {
        if (target_index > self.weights().len) return error.IndexOutOfBounds;
        const buf = try a.dupe(u8, chars);
        var ctx = InsertCharsCtx{ .a = a, .buf = buf, .target_index = target_index };
        const walk_result = ctx.walkToInsert(self);
        return if (walk_result.err) |e| e else walk_result.replace.?;
    }

    test insertChars {
        const a = idc_if_it_leaks;

        // replace empty Leaf with new Leaf with new content
        {
            const root = try Node.fromString(a, "", false);
            const new_root = try root.insertChars(a, 0, "A");
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "A", .noc = 1 }, new_root.leaf);
        }
        {
            const root = try Node.fromString(a, "", true);
            const new_root = try root.insertChars(a, 0, "hello\nworld");
            const new_root_debug_str =
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "", false);
            const new_root = try root.insertChars(a, 0, "hello\nworld");
            const new_root_debug_str =
                \\2 1/11/10
                \\  1 `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }

        // target_index at start of Leaf
        {
            const root = try Node.fromString(a, "BCD", false);
            const new_root = try root.insertChars(a, 0, "A");
            const new_root_debug_str =
                \\2 0/4/4
                \\  1 `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "BCD", true);
            const new_root = try root.insertChars(a, 0, "A");
            const new_root_debug_str =
                \\2 1/4/4
                \\  1 B| `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(a, "BCD", true, true);
            const new_root = try root.insertChars(a, 0, "A");
            const new_root_debug_str =
                \\2 1/5/4
                \\  1 B| `A`
                \\  1 `BCD` |E
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }

        // target_index at end of Leaf
        {
            const root = try Node.fromString(a, "A", false);
            const new_root = try root.insertChars(idc_if_it_leaks, 1, "BCD");
            const new_root_debug_str =
                \\2 0/4/4
                \\  1 `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(idc_if_it_leaks, "A", true, true);
            const new_root = try root.insertChars(idc_if_it_leaks, 1, "BCD");
            const new_root_debug_str =
                \\2 1/5/4
                \\  1 B| `A`
                \\  1 `BCD` |E
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            const new_root = try root.insertChars(a, 3, "_1");
            const new_root_debug_str =
                \\4 4/20/17
                \\  3 2/10/8
                \\    2 1/6/5
                \\      1 B| `one`
                \\      1 `_1` |E
                \\    1 B| `two` |E
                \\  2 2/10/9
                \\    1 B| `three` |E
                \\    1 B| `four`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }

        // target_index at middle of Leaf
        {
            const root = try Leaf.new(a, "ACD", false, false);
            const new_root = try root.insertChars(a, 1, "B");
            const new_root_debug_str =
                \\3 0/4/4
                \\  1 `A`
                \\  2 0/3/3
                \\    1 `B`
                \\    1 `CD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }

        // consecutive insertions
        {
            const acd = try Leaf.new(a, "ACD", false, false);
            const abcd = try acd.insertChars(a, 1, "B");
            const abcde = try abcd.insertChars(a, 4, "E");
            const new_root_debug_str =
                \\4 0/5/5
                \\  1 `A`
                \\  3 0/4/4
                \\    1 `B`
                \\    2 0/3/3
                \\      1 `CD`
                \\      1 `E`
            ;
            try eqStr(new_root_debug_str, try abcde.debugPrint());
        }
        {
            const acd = try Leaf.new(a, "ACD", true, true);
            const abcd = try acd.insertChars(a, 1, "B");
            const abcde = try abcd.insertChars(a, 4, "E");
            const new_root_debug_str =
                \\4 1/6/5
                \\  1 B| `A`
                \\  3 0/5/4
                \\    1 `B`
                \\    2 0/4/3
                \\      1 `CD`
                \\      1 `E` |E
            ;
            try eqStr(new_root_debug_str, try abcde.debugPrint());
        }

        // multi line insert in the middle
        {
            const abcd = try Leaf.new(a, "ABCD", true, false);
            const new_root = try abcd.insertChars(a, 1, "1\n22");
            const new_root_debug_str =
                \\4 2/8/7
                \\  1 B| `A`
                \\  3 1/7/6
                \\    2 1/4/3
                \\      1 `1` |E
                \\      1 B| `22`
                \\    1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
    }

    ///////////////////////////// Node Info

    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }
    test weights {
        const a = idc_if_it_leaks;
        const node = try Node.new(a, try Leaf.new(a, "one", true, false), try Leaf.new(a, "_two", false, true));
        try eqDeep(Leaf{ .bol = true, .eol = false, .buf = "one", .noc = 3 }, node.branch.left.leaf);
        try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "_two", .noc = 4 }, node.branch.right.leaf);
        try eqDeep(Weights{ .bols = 1, .len = 8, .depth = 2, .noc = 7 }, node.weights());
        try eqDeep(Weights{ .bols = 1, .len = 3, .depth = 1, .noc = 3 }, node.branch.left.weights());
        try eqDeep(Weights{ .bols = 0, .len = 5, .depth = 1, .noc = 4 }, node.branch.right.weights());
    }

    ///////////////////////////// Debug Print Node

    fn debugPrint(self: *const Node) ![]const u8 {
        var result = std.ArrayList(u8).init(idc_if_it_leaks);
        try self._debugPrint(idc_if_it_leaks, &result, 0);
        return try result.toOwnedSlice();
    }

    fn _debugPrint(self: *const Node, a: Allocator, result: *std.ArrayList(u8), indent_level: usize) !void {
        if (indent_level > 0) try result.append('\n');
        for (0..indent_level) |_| try result.append(' ');
        switch (self.*) {
            .branch => |branch| {
                const content = try std.fmt.allocPrint(a, "{d} {d}/{d}/{d}", .{ branch.weights.depth, branch.weights.bols, branch.weights.len, branch.weights.noc });
                defer a.free(content);
                try result.appendSlice(content);
                try branch.left._debugPrint(a, result, indent_level + 2);
                try branch.right._debugPrint(a, result, indent_level + 2);
            },
            .leaf => |leaf| {
                try result.appendSlice("1 ");
                if (leaf.bol) try result.appendSlice("B| ");
                try result.append('`');
                try result.appendSlice(leaf.buf);
                try result.append('`');
                if (leaf.eol) try result.appendSlice(" |E");
            },
        }
    }

    test debugPrint {
        const a = idc_if_it_leaks;
        {
            const root = try __inputCharsOneAfterAnother(a, "abcd");
            const expected =
                \\4 0/4/4
                \\  1 `a`
                \\  3 0/3/3
                \\    1 `b`
                \\    2 0/2/2
                \\      1 `c`
                \\      1 `d`
            ;
            try eqStr(expected, try root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            const expected =
                \\3 4/18/15
                \\  2 2/8/6
                \\    1 B| `one` |E
                \\    1 B| `two` |E
                \\  2 2/10/9
                \\    1 B| `three` |E
                \\    1 B| `four`
            ;
            try eqStr(expected, try root.debugPrint());
        }
    }
};

const Branch = struct {
    left: *const Node,
    right: *const Node,
    weights: Weights,
};

const Leaf = struct {
    buf: []const u8,
    bol: bool = true,
    eol: bool = true,
    noc: u32,

    fn new(a: Allocator, source: []const u8, bol: bool, eol: bool) !*const Node {
        if (source.len == 0) return &Node{ .leaf = .{ .buf = "", .noc = 0, .bol = bol, .eol = eol } };
        const node = try a.create(Node);
        node.* = .{ .leaf = .{ .buf = source, .bol = bol, .eol = eol, .noc = getNumOfChars(source) } };
        return node;
    }

    fn weights(self: *const Leaf) Weights {
        var len = self.buf.len;
        if (self.eol) len += 1;
        return Weights{
            .bols = if (self.bol) 1 else 0,
            .len = @intCast(len),
            .noc = self.noc,
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

test {
    std.testing.refAllDeclsRecursive(Node);
}
