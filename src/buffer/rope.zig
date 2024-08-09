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

    pub fn fromFile(a: Allocator, file_path: []const u8) !*const Node {
        const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_only });
        defer file.close();
        const stat = try file.stat();
        return Node.fromReader(a, file.reader(), stat.size, true);
    }

    pub fn fromString(a: Allocator, source: []const u8, first_bol: bool) !*const Node {
        var stream = std.io.fixedBufferStream(source);
        return Node.fromReader(a, stream.reader(), source.len, first_bol);
    }
    test fromString {
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", false);
            const root_debug_str =
                \\2 1/11/10
                \\  1 `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
        }
        {
            const root = try Node.fromString(idc_if_it_leaks, "hello\nworld", true);
            const root_debug_str =
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
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
        if (std.mem.eql(u8, buf, "\n")) {
            var leaves = try a.alloc(Node, 1);
            leaves[0] = .{ .leaf = .{ .buf = "", .noc = 0, .bol = false, .eol = true } };
            return leaves;
        }

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
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "", .noc = 0 }, leaves[0].leaf);
        }
        {
            const leaves = try createLeavesByNewLine(idc_if_it_leaks, "\n");
            try eq(1, leaves.len);
            try eqDeep(Leaf{ .bol = false, .eol = true, .buf = "", .noc = 0 }, leaves[0].leaf);
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
            const root_debug_str =
                \\3 3/18/15
                \\  2 1/8/6
                \\    1 `one` |E
                \\    1 B| `two` |E
                \\  2 2/10/9
                \\    1 B| `three` |E
                \\    1 B| `four`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
        }
    }

    ///////////////////////////// Get Content

    // Walk through entire tree, append each Leaf content to ArrayList(u8), then return that ArrayList(u8).
    pub fn getContent(self: *const Node, a: Allocator) !ArrayList(u8) {
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

    test getContent {
        const a = idc_if_it_leaks;
        {
            const source = "";
            const root = try Node.fromString(a, source, true);
            const result = try root.getContent(a);
            try eqStr(source, result.items);
        }
        {
            const source = "one\ntwo\nthree\nfour";
            const root = try Node.fromString(a, source, true);
            const result = try root.getContent(a);
            try eqStr(source, result.items);
        }
    }

    pub fn getRange(self: *const Node, start_byte: usize, end_byte: usize, buf: []u8, buf_size: usize) ![]u8 {
        const GetRangeCtx = struct {
            start_byte: usize,
            end_byte: usize,
            buf: []u8,
            buf_size: usize,

            should_stop: bool = false,
            current_index: usize = 0,
            bytes_written: usize = 0,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.should_stop == true) return WalkResult.stop;
                switch (node.*) {
                    .branch => |*branch| {
                        const left_end = cx.current_index + branch.left.weights().len;
                        var left_result = WalkResult.keep_walking;
                        if (cx.start_byte < left_end) left_result = cx.walk(branch.left);
                        cx.current_index = left_end;
                        const right_result = cx.walk(branch.right);
                        return WalkResult.merge(left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
                var num_of_bytes_to_write = leaf.buf.len;
                const bytes_left_to_write = cx.end_byte - cx.start_byte - cx.bytes_written;
                if (bytes_left_to_write < leaf.buf.len) {
                    const diff = leaf.buf.len - bytes_left_to_write;
                    num_of_bytes_to_write -= diff;
                }

                // append Leaf's bytes
                const start_index = cx.start_byte -| cx.current_index;
                const end_index = start_index + num_of_bytes_to_write;
                if (end_index <= leaf.buf.len) {
                    var rest = leaf.buf[start_index..end_index];

                    if (cx.bytes_written + rest.len > cx.buf_size) {
                        const room_left = cx.buf_size -| cx.bytes_written;
                        var end = start_index + room_left;
                        while (end > 0) {
                            if (leaf.buf[end - 1] < 128) break;
                            end -= 1;
                        }
                        rest = leaf.buf[start_index..end];
                    }

                    @memcpy(cx.buf[cx.bytes_written .. cx.bytes_written + rest.len], rest);
                    cx.bytes_written += rest.len;
                }

                // append '\n' character
                cx.current_index += leaf.buf.len;
                if (cx.current_index < cx.end_byte and leaf.eol) {
                    cx.buf[cx.bytes_written] = '\n';
                    cx.bytes_written += 1;
                }
                if (leaf.eol) cx.current_index += 1;

                if (cx.current_index >= cx.end_byte) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (start_byte > self.weights().len or end_byte > self.weights().len) return error.IndexOutOfBounds;
        var ctx = GetRangeCtx{ .start_byte = start_byte, .end_byte = end_byte, .buf = buf, .buf_size = buf_size };
        const walk_result = ctx.walk(self);
        if (walk_result.err) |err| return err;
        return ctx.buf[0..ctx.bytes_written];
    }
    test getRange {
        const a = idc_if_it_leaks;
        { // basic
            const source = "one\ntwo\nthree\nfour";
            const buf_size = 1024;
            const root = try Node.fromString(a, source, true);
            try testGetRange(root, buf_size, 0, 1, "o");
            try testGetRange(root, buf_size, 0, 2, "on");
            try testGetRange(root, buf_size, 0, 3, "one");
            try testGetRange(root, buf_size, 0, 4, "one\n");
            try testGetRange(root, buf_size, 0, 5, "one\nt");
            try testGetRange(root, buf_size, 0, 7, "one\ntwo");
            try testGetRange(root, buf_size, 4, 5, "t");
            try testGetRange(root, buf_size, 4, 6, "tw");
            try testGetRange(root, buf_size, 5, 6, "w");
            try testGetRange(root, buf_size, 4, 7, "two");
            try testGetRange(root, buf_size, 5, 7, "wo");
            try testGetRange(root, buf_size, 6, 7, "o");
            try testGetRange(root, buf_size, 7, 8, "\n");
            try testGetRange(root, buf_size, 7, 9, "\nt");
            try testGetRange(root, buf_size, 8, 9, "t");
            try testGetRange(root, buf_size, 8, 13, "three");
            try testGetRange(root, buf_size, 10, 13, "ree");
            try testGetRange(root, buf_size, 0, source.len, source);
        }
    }
    fn testGetRange(root: *const Node, comptime buf_size: usize, start_byte: usize, end_byte: usize, str: []const u8) !void {
        var buf: [buf_size]u8 = undefined;
        const result = try root.getRange(start_byte, end_byte, &buf, buf_size);
        try eqStr(str, result);
    }

    pub fn getRestOfLine(self: *const Node, start_byte: usize, buf: []u8, buf_size: usize) []u8 {
        const GetRestOfLineCtx = struct {
            start_byte: usize,
            buf: []u8,
            buf_size: usize,

            should_stop: bool = false,
            current_index: usize = 0,
            bytes_written: usize = 0,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.should_stop == true) return WalkResult.stop;
                switch (node.*) {
                    .branch => |*branch| {
                        const left_end = cx.current_index + branch.left.weights().len;
                        var left_result = WalkResult.keep_walking;
                        if (cx.start_byte < left_end) left_result = cx.walk(branch.left);
                        cx.current_index = left_end;
                        const right_result = cx.walk(branch.right);
                        return WalkResult.merge(left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
                const num_of_bytes_to_not_include = cx.start_byte -| cx.current_index;
                if (num_of_bytes_to_not_include > leaf.buf.len) @panic("num_of_bytes_to_not_include > leaf.buf.len!");
                var rest = leaf.buf[num_of_bytes_to_not_include..];

                if (cx.bytes_written + rest.len > cx.buf_size) {
                    const room_left = cx.buf_size -| cx.bytes_written;
                    var end = num_of_bytes_to_not_include + room_left;
                    while (end > 0) {
                        if (leaf.buf[end - 1] < 128) break;
                        end -= 1;
                    }
                    rest = leaf.buf[num_of_bytes_to_not_include..end];
                }

                @memcpy(cx.buf[cx.bytes_written .. cx.bytes_written + rest.len], rest);

                cx.bytes_written += rest.len;
                cx.current_index += leaf.weights().len;

                if (leaf.eol) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (start_byte > self.weights().len) return "";
        var ctx = GetRestOfLineCtx{ .start_byte = start_byte, .buf = buf, .buf_size = buf_size };
        const walk_result = ctx.walk(self);
        if (walk_result.err) |_| @panic("Node.getRestOfLine() shouldn't return any errors!");
        return ctx.buf[0..ctx.bytes_written];
    }
    test getRestOfLine {
        const a = idc_if_it_leaks;
        { // basic
            const buf_size = 1024;
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            try testGetRestOfLine(root, buf_size, 0, "one");
            try testGetRestOfLine(root, buf_size, 1, "ne");
            try testGetRestOfLine(root, buf_size, 2, "e");
            try testGetRestOfLine(root, buf_size, 3, ""); // \n
            try testGetRestOfLine(root, buf_size, 4, "two");
            try testGetRestOfLine(root, buf_size, 8, "three");
            try testGetRestOfLine(root, buf_size, 9, "hree");
            try testGetRestOfLine(root, buf_size, 10, "ree");
            try testGetRestOfLine(root, buf_size, 14, "four");
        }
        { // buf_size overflow
            const buf_size = 3;
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            try testGetRestOfLine(root, buf_size, 0, "one");
            try testGetRestOfLine(root, buf_size, 1, "ne");
            try testGetRestOfLine(root, buf_size, 2, "e");
            try testGetRestOfLine(root, buf_size, 3, ""); // \n
            try testGetRestOfLine(root, buf_size, 4, "two");
            try testGetRestOfLine(root, buf_size, 5, "wo");
            try testGetRestOfLine(root, buf_size, 6, "o");
            try testGetRestOfLine(root, buf_size, 7, ""); // \n
            try testGetRestOfLine(root, buf_size, 8, "thr");
            try testGetRestOfLine(root, buf_size, 9, "hre");
            try testGetRestOfLine(root, buf_size, 10, "ree");
            try testGetRestOfLine(root, buf_size, 11, "ee");
            try testGetRestOfLine(root, buf_size, 12, "e");
            try testGetRestOfLine(root, buf_size, 13, ""); // \n
            try testGetRestOfLine(root, buf_size, 14, "fou");
            try testGetRestOfLine(root, buf_size, 15, "our");
            try testGetRestOfLine(root, buf_size, 16, "ur");
            try testGetRestOfLine(root, buf_size, 17, "r");
            try testGetRestOfLine(root, buf_size, 18, ""); // out of bounds
            try testGetRestOfLine(root, buf_size, 19, ""); // out of bounds
            try testGetRestOfLine(root, buf_size, 100, ""); // out of bounds
        }
        // TODO: unicode test cases
    }
    fn testGetRestOfLine(root: *const Node, comptime buf_size: usize, index: usize, str: []const u8) !void {
        var buf: [buf_size]u8 = undefined;
        const result = root.getRestOfLine(index, &buf, buf_size);
        try eqStr(str, result);
    }

    pub fn getLine(self: *const Node, a: Allocator, linenr: u32) !struct { ArrayList(u8), u32 } {
        const GetLineCtx = struct {
            target_linenr: u32,
            current_linenr: u32 = 0,
            result_list: *ArrayList(u8),
            should_stop: bool = false,
            num_of_chars: u32 = 0,

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
                cx.num_of_chars += leaf.noc;
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
        return .{ result_list, ctx.num_of_chars };
    }

    test getLine {
        const a = idc_if_it_leaks;

        { // can get line that contained in 1 single Leaf
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            {
                const line, const noc = try root.getLine(a, 0);
                try eqStr("one", line.items);
                try eq(3, noc);
            }
            {
                const line, const noc = try root.getLine(a, 1);
                try eqStr("two", line.items);
                try eq(3, noc);
            }
            {
                const line, const noc = try root.getLine(a, 2);
                try eqStr("three", line.items);
                try eq(5, noc);
            }
            {
                const line, const noc = try root.getLine(a, 3);
                try eqStr("four", line.items);
                try eq(4, noc);
            }
        }

        // can get line that spans across multiple Leaves
        {
            const old = try Node.fromString(a, "one\ntwo\nthree", true);
            const root, _, _ = try old.insertChars(a, 3, "_1");
            {
                const line, const noc = try root.getLine(a, 0);
                try eqStr("one_1", line.items);
                try eq(5, noc);
            }
            {
                const line, const noc = try root.getLine(a, 1);
                try eqStr("two", line.items);
                try eq(3, noc);
            }
            {
                const line, const noc = try root.getLine(a, 2);
                try eqStr("three", line.items);
                try eq(5, noc);
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
                    const line, const noc = try root.getLine(a, 0);
                    try eqStr("one_two_three", line.items);
                    try eq(13, noc);
                }
                {
                    const line, const noc = try root.getLine(a, 1);
                    try eqStr("four", line.items);
                    try eq(4, noc);
                }
            }
            {
                const root = try Node.new(a, four, one_two_three);
                {
                    const line, const noc = try root.getLine(a, 0);
                    try eqStr("four", line.items);
                    try eq(4, noc);
                }
                {
                    const line, const noc = try root.getLine(a, 1);
                    try eqStr("one_two_three", line.items);
                    try eq(13, noc);
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

    pub fn balance(self: *const Node, a: Allocator) !*const Node {
        switch (self.*) {
            .leaf => return self,
            .branch => |branch| {
                {
                    const initial_balance_factor = calculateBalanceFactor(branch.left, branch.right);
                    if (@abs(initial_balance_factor) < MAX_IMBALANCE) return self;
                }

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
            root, _, _ = try root.insertChars(a, root.weights().len, chars[i .. i + 1]);
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
            const abcd, _, _ = try abc.insertChars(a, 1, "B");
            const root, _, _ = try abcd.insertChars(a, 1, "a");
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
            const abcd, _, _ = try acd.insertChars(a, 1, "B");
            const old_root, _, _ = try abcd.insertChars(a, 4, "E");
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

    pub fn deleteBytes(self: *const Node, a: Allocator, start_byte: usize, num_of_bytes_to_delete: usize) !*const Node {
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
                    .leaf => |leaf| return cx.walker(&leaf) catch |err| return .{ .err = err },
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                defer cx.leaves_encountered += 1;

                const leaf_outside_delete_range = cx.current_index.* >= cx.end_byte;
                if (leaf_outside_delete_range) return try _amendBol(cx, leaf);

                const start_before_leaf = cx.start_byte <= cx.current_index.*;
                const end_after_leaf = cx.end_byte >= cx.current_index.* + leaf.weights().len - 1;
                const delete_covers_leaf = start_before_leaf and end_after_leaf;
                if (delete_covers_leaf) return try _removed(cx, leaf);

                const start_in_leaf = cx.current_index.* <= cx.start_byte;
                const end_in_leaf = cx.current_index.* + leaf.buf.len >= cx.end_byte;
                const leaf_covers_delete = start_in_leaf and end_in_leaf;

                if (leaf_covers_delete) return try _trimmedLeftAndTrimmedRight(cx, leaf);
                if (start_in_leaf) return try _leftSide(cx, leaf);
                if (end_in_leaf) return try _rightSide(cx, leaf);

                unreachable;
            }

            fn _amendBol(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                if (cx.first_leaf_bol) |bol| {
                    const replace = try Leaf.new(cx.a, leaf.buf, bol, leaf.eol);
                    return WalkMutResult{ .replace = replace };
                }
                return WalkMutResult.stop;
            }

            fn _removed(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                cx.bytes_deleted += leaf.weights().len;
                if (cx.leaves_encountered == 0) cx.first_leaf_bol = leaf.bol;
                if (leaf.eol) {
                    const replace = try Leaf.new(cx.a, "", false, true);
                    return WalkMutResult{ .replace = replace };
                }
                return WalkMutResult.removed;
            }

            fn _trimmedLeftAndTrimmedRight(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                const split_index = cx.start_byte - cx.current_index.*;
                const left_side_content = leaf.buf[0..split_index];
                const right_side_content = leaf.buf[split_index + cx.num_of_bytes_to_delete .. leaf.buf.len];

                const left_side_wiped_out = left_side_content.len == 0;
                if (left_side_wiped_out) {
                    const right_side = try Leaf.new(cx.a, right_side_content, leaf.bol, leaf.eol);
                    return WalkMutResult{ .replace = right_side };
                }

                const right_side_wiped_out = right_side_content.len == 0;
                if (right_side_wiped_out) {
                    const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, leaf.eol);
                    return WalkMutResult{ .replace = left_side };
                }

                const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, false);
                const right_side = try Leaf.new(cx.a, right_side_content, false, leaf.eol);
                const replace = try Node.new(cx.a, left_side, right_side);
                return WalkMutResult{ .replace = replace };
            }

            fn _leftSide(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                const split_index = cx.start_byte - cx.current_index.*;
                const left_side_content = leaf.buf[0..split_index];
                const left_eol = if (left_side_content.len == leaf.buf.len) false else leaf.eol;
                const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, left_eol);
                cx.bytes_deleted += leaf.buf.len - left_side_content.len;
                if (left_side_content.len == leaf.buf.len) cx.bytes_deleted += 1;
                return WalkMutResult{ .replace = left_side };
            }

            fn _rightSide(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                const bytes_left_to_delete = cx.num_of_bytes_to_delete - cx.bytes_deleted;
                const right_side_content = leaf.buf[bytes_left_to_delete..];
                const right_side = try Leaf.new(cx.a, right_side_content, leaf.bol, leaf.eol);
                return WalkMutResult{ .replace = right_side };
            }
        };

        const end_byte = start_byte + num_of_bytes_to_delete;
        if (end_byte > self.weights().len) return error.IndexOutOfBounds;

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

        // delete operation spans aceoss lines
        {
            const root = try Node.fromString(a, "Hello\nWorld!", true);
            const root_debug_str =
                \\2 2/12/11
                \\  1 B| `Hello` |E
                \\  1 B| `World!`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            const new_root = try root.deleteBytes(a, 5, 1);
            const new_root_debug_str =
                \\2 2/11/11
                \\  1 B| `Hello`
                \\  1 B| `World!`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "Hello\nfrom\nEarth", true);
            const root_debug_str =
                \\3 3/16/14
                \\  1 B| `Hello` |E
                \\  2 2/10/9
                \\    1 B| `from` |E
                \\    1 B| `Earth`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            {
                const new_root = try root.deleteBytes(a, 5, 1);
                const new_root_debug_str =
                    \\3 3/15/14
                    \\  1 B| `Hello`
                    \\  2 2/10/9
                    \\    1 B| `from` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 2);
                const new_root_debug_str =
                    \\3 3/14/13
                    \\  1 B| `Hello`
                    \\  2 2/9/8
                    \\    1 B| `rom` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 3);
                const new_root_debug_str =
                    \\3 3/13/12
                    \\  1 B| `Hello`
                    \\  2 2/8/7
                    \\    1 B| `om` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 4);
                const new_root_debug_str =
                    \\3 3/12/11
                    \\  1 B| `Hello`
                    \\  2 2/7/6
                    \\    1 B| `m` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 5);
                const new_root_debug_str =
                    \\3 2/11/10
                    \\  1 B| `Hello`
                    \\  2 1/6/5
                    \\    1 `` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
                const new_document = try new_root.getContent(a);
                try eqStr("Hello\nEarth", new_document.items);
            }
        }
    }

    ///////////////////////////// Insert Chars

    pub fn insertChars(
        self: *const Node,
        a: Allocator,
        target_index: usize,
        chars: []const u8,
    ) !struct { *const Node, usize, usize } {
        const InsertCharsCtx = struct {
            a: Allocator,
            buf: []const u8,
            target_index: usize,
            current_index: usize = 0,
            num_of_new_lines: usize = 0,
            last_new_leaf_noc: usize = 0,

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
                    .leaf => |leaf| return ctx.walker(&leaf) catch |err| return .{ .err = err },
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                var new_leaves = try createLeavesByNewLine(cx.a, cx.buf);
                if (new_leaves.len > 1) cx.num_of_new_lines = new_leaves.len - 1;
                if (new_leaves.len > 0) cx.last_new_leaf_noc = new_leaves[new_leaves.len - 1].weights().noc;

                if (leaf.buf.len == 0) {
                    new_leaves[0].leaf.bol = leaf.bol;
                    const replacement = try mergeLeaves(cx.a, new_leaves);
                    return WalkMutResult{ .replace = replacement };
                }

                const insert_at_start = cx.current_index == cx.target_index;
                if (insert_at_start) {
                    new_leaves[0].leaf.bol = leaf.bol;
                    const left = try mergeLeaves(cx.a, new_leaves);
                    const right = try Leaf.new(cx.a, leaf.buf, false, leaf.eol);
                    const replacement = try Node.new(cx.a, left, right);
                    return WalkMutResult{ .replace = replacement };
                }

                const insert_at_end = cx.current_index + leaf.buf.len == cx.target_index;
                if (insert_at_end) {
                    new_leaves[new_leaves.len - 1].leaf.eol = leaf.eol;
                    const left = try Leaf.new(cx.a, leaf.buf, leaf.bol, false);
                    const right = try mergeLeaves(cx.a, new_leaves);
                    const replacement = try Node.new(cx.a, left, right);
                    return WalkMutResult{ .replace = replacement };
                }

                // insert in middle
                const split_index = cx.target_index - cx.current_index;
                const left_split = leaf.buf[0..split_index];
                const right_split = leaf.buf[split_index..leaf.buf.len];

                var first_eol = false;
                if (cx.buf[0] == '\n') first_eol = true;

                var last_bol = false;
                if (new_leaves.len > 1) {
                    const last_new_leaf = new_leaves[new_leaves.len - 1].leaf;
                    if (last_new_leaf.buf.len == 0 and last_new_leaf.bol) last_bol = true;
                }

                const first = Node{ .leaf = .{ .buf = left_split, .noc = getNumOfChars(left_split), .bol = leaf.bol, .eol = first_eol } };
                const last = Node{ .leaf = .{ .buf = right_split, .noc = getNumOfChars(right_split), .bol = last_bol, .eol = leaf.eol } };

                var list = try std.ArrayList(Node).initCapacity(cx.a, new_leaves.len + 2);
                try list.append(first);
                for (new_leaves, 0..) |nl, i| {
                    if (i == 0 and cx.buf[0] == '\n') continue;
                    if (i == new_leaves.len - 1 and last_bol == true) continue;
                    try list.append(nl);
                }
                try list.append(last);
                defer cx.a.free(new_leaves);

                const merged = try mergeLeaves(cx.a, list.items);
                return WalkMutResult{ .replace = merged };
            }
        };
        if (chars.len == 0) return error.EmptyStringNotAllowed;
        if (target_index > self.weights().len) return error.IndexOutOfBounds;
        const buf = try a.dupe(u8, chars);
        var ctx = InsertCharsCtx{ .a = a, .buf = buf, .target_index = target_index };
        const walk_result = ctx.walkToInsert(self);
        if (walk_result.err) |e| return e;
        return .{ walk_result.replace.?, ctx.num_of_new_lines, ctx.last_new_leaf_noc };
    }

    test insertChars {
        const a = idc_if_it_leaks;

        // replace empty Leaf with new Leaf with new content
        {
            const root = try Node.fromString(a, "", false);
            const new_root, _, _ = try root.insertChars(a, 0, "A");
            try eqDeep(Leaf{ .bol = false, .eol = false, .buf = "A", .noc = 1 }, new_root.leaf);
        }
        {
            const root = try Node.fromString(a, "", true);
            const new_root, _, _ = try root.insertChars(a, 0, "hello\nworld");
            const new_root_debug_str =
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "", false);
            const new_root, _, _ = try root.insertChars(a, 0, "hello\nworld");
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
            const new_root, _, _ = try root.insertChars(a, 0, "A");
            const new_root_debug_str =
                \\2 0/4/4
                \\  1 `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "BCD", true);
            const new_root, _, _ = try root.insertChars(a, 0, "A");
            const new_root_debug_str =
                \\2 1/4/4
                \\  1 B| `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(a, "BCD", true, true);
            const new_root, _, _ = try root.insertChars(a, 0, "A");
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
            const new_root, _, _ = try root.insertChars(idc_if_it_leaks, 1, "BCD");
            const new_root_debug_str =
                \\2 0/4/4
                \\  1 `A`
                \\  1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(idc_if_it_leaks, "A", true, true);
            const new_root, _, _ = try root.insertChars(idc_if_it_leaks, 1, "BCD");
            const new_root_debug_str =
                \\2 1/5/4
                \\  1 B| `A`
                \\  1 `BCD` |E
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
            const new_root, _, _ = try root.insertChars(a, 3, "_1");
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
            const new_root, _, _ = try root.insertChars(a, 1, "B");
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
            const abcd, _, _ = try acd.insertChars(a, 1, "B");
            const abcde, _, _ = try abcd.insertChars(a, 4, "E");
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
            const abcd, _, _ = try acd.insertChars(a, 1, "B");
            const abcde, _, _ = try abcd.insertChars(a, 4, "E");
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
        {
            const root = try Leaf.new(a, "const str =;", true, false);
            const new_root, _, _ = try root.insertChars(a, 11, "\n");
            const new_root_debug_str =
                \\2 1/13/12
                \\  1 B| `const str =` |E
                \\  1 `;`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }

        // multi line insert in the middle
        {
            const abcd = try Leaf.new(a, "ABCD", true, false);
            const new_root, _, _ = try abcd.insertChars(a, 1, "1\n22");
            const new_root_debug_str =
                \\3 2/8/7
                \\  2 1/3/2
                \\    1 B| `A`
                \\    1 `1` |E
                \\  2 1/5/5
                \\    1 B| `22`
                \\    1 `BCD`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(a, "const str =;", true, false);
            const new_root, _, _ = try root.insertChars(a, 11, "\n    \\\\hello\n    \\\\world\n");
            const new_root_debug_str =
                \\3 4/37/34
                \\  2 2/24/22
                \\    1 B| `const str =` |E
                \\    1 B| `    \\hello` |E
                \\  2 2/13/12
                \\    1 B| `    \\world` |E
                \\    1 B| `;`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
    }

    ///////////////////////////// Get Byte Offset from Position

    pub fn getByteOffsetOfPosition(self: *const Node, line: usize, col: usize) !usize {
        const GetByteOffsetCtx = struct {
            byte_offset: usize = 0,
            current_linenr: usize = 0,
            current_colnr: usize = 0,
            should_stop: bool = false,
            encountered_bol: bool = false,
            target_linenr: usize,
            target_colnr: usize,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.should_stop) return WalkResult.stop;
                switch (node.*) {
                    .branch => |branch| {
                        const left_bols_end = cx.current_linenr + branch.left.weights().bols;
                        var left_result = WalkResult.keep_walking;
                        if (cx.target_linenr == cx.current_linenr or cx.target_linenr < left_bols_end) left_result = cx.walk(branch.left);
                        if (cx.target_linenr > cx.current_linenr) cx.byte_offset += branch.left.weights().len;
                        cx.current_linenr = left_bols_end;
                        const right_result = cx.walk(branch.right);
                        return WalkResult.merge(left_result, right_result);
                    },
                    .leaf => |leaf| return cx.walker(&leaf),
                }
            }

            fn walker(cx: *@This(), leaf: *const Leaf) WalkResult {
                if (leaf.bol) cx.encountered_bol = true;

                if (cx.encountered_bol and cx.target_colnr == 0) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }

                const sum = cx.current_colnr + leaf.noc;
                if (sum <= cx.target_colnr) {
                    cx.current_colnr += leaf.noc;
                    cx.byte_offset += leaf.buf.len;
                }
                if (sum > cx.target_colnr) {
                    var iter = code_point.Iterator{ .bytes = leaf.buf };
                    while (iter.next()) |cp| {
                        cx.current_colnr += 1;
                        cx.byte_offset += cp.len;
                        if (cx.current_colnr >= cx.target_colnr) break;
                    }
                }
                if (cx.encountered_bol and (leaf.eol or sum >= cx.target_colnr)) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }

                if (leaf.eol) cx.byte_offset += 1;
                return WalkResult.keep_walking;
            }
        };

        if (line > self.weights().bols) return error.LineOutOfBounds;
        var ctx = GetByteOffsetCtx{ .target_linenr = line, .target_colnr = col };
        if (ctx.walk(self).err) |err| return err else {
            if (ctx.current_colnr < col) return error.ColOutOfBounds;
            return ctx.byte_offset;
        }
    }
    test getByteOffsetOfPosition {
        const a = idc_if_it_leaks;
        {
            const root = try Node.fromString(a, "Hello World!", true);
            try shouldErr(error.LineOutOfBounds, root.getByteOffsetOfPosition(3, 0));
            try shouldErr(error.LineOutOfBounds, root.getByteOffsetOfPosition(2, 0));
            try eq(0, root.getByteOffsetOfPosition(0, 0));
            try eq(1, root.getByteOffsetOfPosition(0, 1));
            try eq(2, root.getByteOffsetOfPosition(0, 2));
            try eq(11, root.getByteOffsetOfPosition(0, 11));
            try eq(12, root.getByteOffsetOfPosition(0, 12));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 13));
        }
        {
            const source = "one\ntwo\nthree\nfour";
            const root = try Node.fromString(a, source, true);

            try eqStr("o", source[0..1]);
            try eq(0, root.getByteOffsetOfPosition(0, 0));
            try eqStr("e", source[2..3]);
            try eq(2, root.getByteOffsetOfPosition(0, 2));
            try eqStr("\n", source[3..4]);
            try eq(3, root.getByteOffsetOfPosition(0, 3));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 4));

            try eqStr("t", source[4..5]);
            try eq(4, root.getByteOffsetOfPosition(1, 0));
            try eqStr("o", source[6..7]);
            try eq(6, root.getByteOffsetOfPosition(1, 2));
            try eqStr("\n", source[7..8]);
            try eq(7, root.getByteOffsetOfPosition(1, 3));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(1, 4));

            try eqStr("t", source[8..9]);
            try eq(8, root.getByteOffsetOfPosition(2, 0));
            try eqStr("e", source[12..13]);
            try eq(12, root.getByteOffsetOfPosition(2, 4));
            try eqStr("\n", source[13..14]);
            try eq(13, root.getByteOffsetOfPosition(2, 5));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(2, 6));

            try eqStr("f", source[14..15]);
            try eq(14, root.getByteOffsetOfPosition(3, 0));
            try eqStr("r", source[17..18]);
            try eq(17, root.getByteOffsetOfPosition(3, 3));
            // no eol on this line
            try eq(18, source.len);
            try eq(18, root.getByteOffsetOfPosition(3, 4));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(3, 5));
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
                try eq(0, root.getByteOffsetOfPosition(0, 0));
                try eqStr("e", txt[12..13]);
                try eq(13, root.getByteOffsetOfPosition(0, 13));
                try eqStr("\n", txt[13..14]);
                try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 14));

                try eqStr("f", txt[14..15]);
                try eq(14, root.getByteOffsetOfPosition(1, 0));
                try eqStr("r", txt[17..18]);
                try eq(18, root.getByteOffsetOfPosition(1, 4));
                try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(1, 5));
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
            try eqStr(root_debug_str, try root.debugPrint());
            try eq(11, root.getByteOffsetOfPosition(0, 11));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 12));
            try eq(23, root.getByteOffsetOfPosition(1, 11));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(1, 12));
            try eq(35, root.getByteOffsetOfPosition(2, 11));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(2, 12));
            try eq(36, root.getByteOffsetOfPosition(3, 0));
            try eq(37, root.getByteOffsetOfPosition(3, 1));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(3, 2));
        }
    }

    ///////////////////////////// Node Info

    fn weights(self: *const Node) Weights {
        return switch (self.*) {
            .branch => |*b| b.weights,
            .leaf => |*l| l.weights(),
        };
    }

    ///////////////////////////// Debug Print Node

    pub fn debugPrint(self: *const Node) ![]const u8 {
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
                const bol = if (leaf.bol) "B| " else "";
                const eol = if (leaf.eol) " |E" else "";
                const leaf_content = if (leaf.buf.len > 0) leaf.buf else "";
                const content = try std.fmt.allocPrint(a, "1 {s}`{s}`{s}", .{ bol, leaf_content, eol });
                defer a.free(content);
                try result.appendSlice(content);
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

    const empty_leaf: Node = .{ .leaf = .{ .buf = "", .noc = 0, .bol = false, .eol = false } };
    const empty_bol_leaf: Node = .{ .leaf = .{ .buf = "", .noc = 0, .bol = true, .eol = false } };
    const empty_eol_leaf: Node = .{ .leaf = .{ .buf = "", .noc = 0, .bol = false, .eol = true } };
    const empty_line_leaf: Node = .{ .leaf = .{ .buf = "", .noc = 0, .bol = true, .eol = true } };

    fn new(a: Allocator, source: []const u8, bol: bool, eol: bool) !*const Node {
        if (source.len == 0) {
            if (!bol and !eol) return &empty_leaf;
            if (bol and !eol) return &empty_bol_leaf;
            if (!bol and eol) return &empty_eol_leaf;
            return &empty_line_leaf;
        }
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
