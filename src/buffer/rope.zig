const std = @import("std");
pub const code_point = @import("code_point");
const ztracy = @import("ztracy");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqDeep = std.testing.expectEqualDeep;
const eqStr = std.testing.expectEqualStrings;
const shouldErr = std.testing.expectError;
const idc_if_it_leaks = std.heap.page_allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

// Copied & edited from https://github.com/neurocyte/flow
// https://github.com/neurocyte/flow/blob/master/src/buffer/Buffer.zig

//////////////////////////////////////////////////////////////////////////////////////////////

/// Represents the result of a walk operation on a Leaf where new Nodes might be created.
/// Used to create a new version of the document (insert, delete).
const WalkMutError = error{OutOfMemory};
const WalkMutResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?WalkMutError = null,

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

/// Represents the result of a walk operation on a Leaf where there will be 0 new Nodes created in the process.
/// Used to get information about the document.
const WalkError = error{OutOfMemory};
const WalkResult = struct {
    keep_walking: bool = false,
    found: bool = false,
    err: ?WalkError = null,

    const F = *const fn (ctx: *anyopaque, leaf: *const Leaf) WalkResult;

    const keep_walking = WalkResult{ .keep_walking = true };
    const stop = WalkResult{ .keep_walking = false };
    const found = WalkResult{ .found = true };

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
/// Nodes are always immutable.
/// For edit operations, new nodes and trees are created.
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

    const CreateLeavesByNewLineError = error{ OutOfMemory, Unexpected };
    fn createLeavesByNewLine(a: std.mem.Allocator, buf: []const u8) CreateLeavesByNewLineError![]Node {
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

    /// Walk through entire tree, append each Leaf content to ArrayList(u8), then return that ArrayList(u8).
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

    /// Walk to Leaf at `start_byte`, write Leaf contents from `start_byte` to `end_byte`
    /// to given []u8 buffer or until it's full.
    pub fn getRange(self: *const Node, start_byte: usize, end_byte: usize, buf: []u8, buf_size: usize) ![]u8 {
        const zone = ztracy.ZoneNC(@src(), "Rope.getRange()", 0xFF00FF);
        defer zone.End();

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
                { // write Leaf's bytes
                    var num_of_bytes_to_write = leaf.buf.len;
                    const bytes_left_to_write = cx.end_byte - cx.start_byte - cx.bytes_written;
                    if (bytes_left_to_write < leaf.buf.len) {
                        const diff = leaf.buf.len - bytes_left_to_write;
                        num_of_bytes_to_write -= diff;
                    }

                    const start_index = cx.start_byte -| cx.current_index;
                    var end_index = start_index + num_of_bytes_to_write;
                    if (end_index > leaf.buf.len) end_index = leaf.buf.len;
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

                { // write '\n' character
                    cx.current_index += leaf.buf.len;
                    if ((cx.current_index < cx.end_byte) and (cx.bytes_written < cx.buf_size) and leaf.eol) {
                        cx.buf[cx.bytes_written] = '\n';
                        cx.bytes_written += 1;
                    }
                    if (leaf.eol) cx.current_index += 1;
                }

                if ((cx.current_index >= cx.end_byte) or (cx.bytes_written >= cx.buf_size)) {
                    cx.should_stop = true;
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (start_byte > self.weights().len or end_byte > self.weights().len) return error.IndexOutOfBounds;
        if (start_byte > end_byte) return error.StarByteLargerThanEndByte;
        var ctx = GetRangeCtx{ .start_byte = start_byte, .end_byte = end_byte, .buf = buf, .buf_size = buf_size };
        const walk_result = ctx.walk(self);
        if (walk_result.err) |err| return err;

        zone.Text(ctx.buf[0..ctx.bytes_written]);

        return ctx.buf[0..ctx.bytes_written];
    }
    test getRange {
        const a = idc_if_it_leaks;
        const source = "one\ntwo\nthree\nfour";
        const root = try Node.fromString(a, source, true);
        { // basic
            const buf_size = 1024;
            try testGetRange(root, buf_size, 0, 0, "");
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
        { // buf_size overflow
            const buf_size = 3;
            try testGetRange(root, buf_size, 0, 1, "o");
            try testGetRange(root, buf_size, 0, 3, "one");
            try testGetRange(root, buf_size, 0, 4, "one");
            try testGetRange(root, buf_size, 3, 4, "\n");
            try testGetRange(root, buf_size, 1, 2, "n");
            try testGetRange(root, buf_size, 1, 3, "ne");
            try testGetRange(root, buf_size, 1, 4, "ne\n");
            try testGetRange(root, buf_size, 1, 10, "ne\n");
            try testGetRange(root, buf_size, 8, 9, "t");
            try testGetRange(root, buf_size, 8, 10, "th");
            try testGetRange(root, buf_size, 8, 13, "thr");
        }
    }
    fn testGetRange(root: *const Node, comptime buf_size: usize, start_byte: usize, end_byte: usize, str: []const u8) !void {
        var buf: [buf_size]u8 = undefined;
        const result = try root.getRange(start_byte, end_byte, &buf, buf_size);
        try eqStr(str, result);
    }

    /// Walk to Leaf at `start_byte`, write Leaf contents until reaches `eol` to given []u8 buffer or until it's full.
    pub fn getRestOfLine(self: *const Node, start_byte: usize, buf: []u8, buf_size: usize) struct { []u8, bool } {
        const zone = ztracy.ZoneNC(@src(), "Rope.getRestOfLine()", 0x33AA33);
        defer zone.End();

        const GetRestOfLineCtx = struct {
            start_byte: usize,
            buf: []u8,
            buf_size: usize,

            found_eol: bool = false,
            buffer_overflowed: bool = false,
            current_index: usize = 0,
            bytes_written: usize = 0,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.found_eol == true) return WalkResult.stop;
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
                var num_of_bytes_to_not_include = cx.start_byte -| cx.current_index;

                if (leaf.buf.len == 0) {
                    if (leaf.eol) {
                        if (cx.bytes_written >= cx.buf_size) cx.buffer_overflowed = true;
                        cx.found_eol = true;
                        return WalkResult.stop;
                    }
                    return WalkResult.keep_walking;
                }

                if (num_of_bytes_to_not_include > leaf.buf.len and leaf.eol) num_of_bytes_to_not_include -= 1;
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
                    if (cx.bytes_written >= cx.buf_size) cx.buffer_overflowed = true;
                    cx.found_eol = true;
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (start_byte > self.weights().len) return .{ "", false };
        var ctx = GetRestOfLineCtx{ .start_byte = start_byte, .buf = buf, .buf_size = buf_size };
        const walk_result = ctx.walk(self);
        if (walk_result.err) |_| @panic("Node.getRestOfLine() shouldn't return any errors!");

        zone.Text(ctx.buf[0..ctx.bytes_written]);

        return .{ ctx.buf[0..ctx.bytes_written], ctx.found_eol and !ctx.buffer_overflowed };
    }
    test getRestOfLine {
        const a = idc_if_it_leaks;

        { // basic
            const buf_size = 1024;
            {
                const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
                try testGetRestOfLine(root, buf_size, 0, "one", true);
                try testGetRestOfLine(root, buf_size, 1, "ne", true);
                try testGetRestOfLine(root, buf_size, 2, "e", true);
                try testGetRestOfLine(root, buf_size, 3, "", true); // \n
                try testGetRestOfLine(root, buf_size, 4, "two", true);
                try testGetRestOfLine(root, buf_size, 8, "three", true);
                try testGetRestOfLine(root, buf_size, 9, "hree", true);
                try testGetRestOfLine(root, buf_size, 10, "ree", true);
                try testGetRestOfLine(root, buf_size, 14, "four", false);
            }
            {
                const root = try Node.fromString(a, "one\n\ntwo\nthree", true);
                try testGetRestOfLine(root, buf_size, 0, "one", true);
                try testGetRestOfLine(root, buf_size, 2, "e", true);
                try testGetRestOfLine(root, buf_size, 3, "", true); // \n
                try testGetRestOfLine(root, buf_size, 4, "", true); // \n
                try testGetRestOfLine(root, buf_size, 5, "two", true);
                try testGetRestOfLine(root, buf_size, 6, "wo", true);
                try testGetRestOfLine(root, buf_size, 7, "o", true);
                try testGetRestOfLine(root, buf_size, 8, "", true); // \n
                try testGetRestOfLine(root, buf_size, 9, "three", false);
                try testGetRestOfLine(root, buf_size, 10, "hree", false);
            }
            {
                const root = try __inputCharsOneAfterAnother(a, "1\n22\n333\n4444");
                const root_debug_str =
                    \\10 4/13/10
                    \\  1 B| `1` |E
                    \\  9 3/11/9
                    \\    1 B| `2`
                    \\    8 2/10/8
                    \\      1 `2` |E
                    \\      7 2/8/7
                    \\        1 B| `3`
                    \\        6 1/7/6
                    \\          1 `3`
                    \\          5 1/6/5
                    \\            1 `3` |E
                    \\            4 1/4/4
                    \\              1 B| `4`
                    \\              3 0/3/3
                    \\                1 `4`
                    \\                2 0/2/2
                    \\                  1 `4`
                    \\                  1 `4`
                ;
                try eqStr(root_debug_str, try root.debugPrint());
                try testGetRestOfLine(root, buf_size, 0, "1", true);
                try testGetRestOfLine(root, buf_size, 1, "", true);
                try testGetRestOfLine(root, buf_size, 2, "22", true);
                try testGetRestOfLine(root, buf_size, 3, "2", true);
                try testGetRestOfLine(root, buf_size, 4, "", true);
                try testGetRestOfLine(root, buf_size, 5, "333", true);
                try testGetRestOfLine(root, buf_size, 6, "33", true);
                try testGetRestOfLine(root, buf_size, 7, "3", true);
                try testGetRestOfLine(root, buf_size, 8, "", true);
                try testGetRestOfLine(root, buf_size, 9, "4444", false);
                try testGetRestOfLine(root, buf_size, 10, "444", false);
                try testGetRestOfLine(root, buf_size, 11, "44", false);
                try testGetRestOfLine(root, buf_size, 12, "4", false);
                try testGetRestOfLine(root, buf_size, 13, "", false);
                try testGetRestOfLine(root, buf_size, 14, "", false);
                try testGetRestOfLine(root, buf_size, 999, "", false);
            }
        }
        { // buf_size overflow
            {
                const buf_size = 1;
                const root = try Node.fromString(a, "one\n\ntwo\nthree", true);
                try testGetRestOfLine(root, buf_size, 0, "o", false);
                try testGetRestOfLine(root, buf_size, 2, "e", false);
                try testGetRestOfLine(root, buf_size, 3, "", true); // \n
                try testGetRestOfLine(root, buf_size, 4, "", true); // \n
                try testGetRestOfLine(root, buf_size, 5, "t", false);
            }
            {
                const buf_size = 2;
                const root = try Node.fromString(a, "one\n\ntwo\nthree", true);
                try testGetRestOfLine(root, buf_size, 0, "on", false);
                try testGetRestOfLine(root, buf_size, 1, "ne", false);
                try testGetRestOfLine(root, buf_size, 2, "e", true);
                try testGetRestOfLine(root, buf_size, 3, "", true);
                try testGetRestOfLine(root, buf_size, 4, "", true);
                try testGetRestOfLine(root, buf_size, 5, "tw", false);
            }
            {
                const buf_size = 3;
                const root = try Node.fromString(a, "one\ntwo\nthree\nfour", true);
                try testGetRestOfLine(root, buf_size, 0, "one", false);
                try testGetRestOfLine(root, buf_size, 1, "ne", true);
                try testGetRestOfLine(root, buf_size, 2, "e", true);
                try testGetRestOfLine(root, buf_size, 3, "", true); // \n
                try testGetRestOfLine(root, buf_size, 4, "two", false);
                try testGetRestOfLine(root, buf_size, 5, "wo", true);
                try testGetRestOfLine(root, buf_size, 6, "o", true);
                try testGetRestOfLine(root, buf_size, 7, "", true); // \n
                try testGetRestOfLine(root, buf_size, 8, "thr", false);
                try testGetRestOfLine(root, buf_size, 9, "hre", false);
                try testGetRestOfLine(root, buf_size, 10, "ree", false);
                try testGetRestOfLine(root, buf_size, 11, "ee", true);
                try testGetRestOfLine(root, buf_size, 12, "e", true);
                try testGetRestOfLine(root, buf_size, 13, "", true); // \n
                try testGetRestOfLine(root, buf_size, 14, "fou", false);
                try testGetRestOfLine(root, buf_size, 15, "our", false);
                try testGetRestOfLine(root, buf_size, 16, "ur", false);
                try testGetRestOfLine(root, buf_size, 17, "r", false);
                try testGetRestOfLine(root, buf_size, 18, "", false); // out of bounds
                try testGetRestOfLine(root, buf_size, 19, "", false); // out of bounds
                try testGetRestOfLine(root, buf_size, 100, "", false); // out of bounds
            }
        }
        // TODO: unicode test cases
    }
    fn testGetRestOfLine(root: *const Node, comptime buf_size: usize, index: usize, str: []const u8, expected_eol: bool) !void {
        var buf: [buf_size]u8 = undefined;
        const result, const eol = root.getRestOfLine(index, &buf, buf_size);
        try eqStr(str, result);
        try eq(expected_eol, eol);
    }

    ///////////////////////////// getLineEx

    const GetLineExError = error{ OutOfMemory, LineOutOfBounds };
    pub fn getLineEx(self: *const Node, a: Allocator, line: usize) GetLineExError![]u21 {
        const zone = ztracy.ZoneNC(@src(), "Rope.getLineEx()", 0x00AA00);
        defer zone.End();

        const GetLineExCtx = struct {
            list: ArrayList(u21),
            fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkResult {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                var iter = code_point.Iterator{ .bytes = leaf.buf };
                while (iter.next()) |cp| {
                    ctx.list.append(cp.code) catch |err| return .{ .err = err };
                }
                if (leaf.eol) return WalkResult.stop;
                return WalkResult.keep_walking;
            }
        };

        if (line > self.weights().bols) return error.LineOutOfBounds;

        var list = try ArrayList(u21).initCapacity(a, 128);
        errdefer list.deinit();

        var ctx = GetLineExCtx{ .list = list };
        const walk_result = self.walkLine(line, GetLineExCtx.walker, &ctx);

        if (walk_result.err) |err| return err;
        return ctx.list.toOwnedSlice();
    }

    ///////////////////////////// getLine

    pub fn getLine(self: *const Node, a: Allocator, line: usize) ![]const u8 {
        const GetLineToArrayListCtx = struct {
            list: ArrayList(u8),
            fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkResult {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.list.appendSlice(leaf.buf) catch |err| return .{ .err = err };
                if (leaf.eol) {
                    ctx.list.append('\n') catch |err| return .{ .err = err };
                    return WalkResult.stop;
                }
                return WalkResult.keep_walking;
            }
        };

        if (line > self.weights().bols) return "";

        var list = try ArrayList(u8).initCapacity(a, 1024);
        errdefer list.deinit();

        var ctx = GetLineToArrayListCtx{ .list = list };
        const walk_result = self.walkLine(line, GetLineToArrayListCtx.walker, &ctx);

        if (walk_result.err) |err| return err;
        return ctx.list.toOwnedSlice();
    }
    test getLine {
        const a = idc_if_it_leaks;
        {
            const root = try Node.fromString(a, "1\n22\n333\n4444", true);
            const got = try root.getLine(std.testing.allocator, 0);
            defer std.testing.allocator.free(got);
            try eqStr("1\n", got);
        }
        {
            const root = try Node.fromString(a, "1\n22\n333\n4444", true);
            try eqStr("1\n", try root.getLine(a, 0));
            try eqStr("22\n", try root.getLine(a, 1));
            try eqStr("333\n", try root.getLine(a, 2));
            try eqStr("4444", try root.getLine(a, 3));
        }
        {
            const root = try __inputCharsOneAfterAnother(a, "1\n22\n333\n4444");
            try eqStr("1\n", try root.getLine(a, 0));
            try eqStr("22\n", try root.getLine(a, 1));
            try eqStr("333\n", try root.getLine(a, 2));
            try eqStr("4444", try root.getLine(a, 3));
        }
    }

    ///////////////////////////// getNumOfCharsOfLine

    pub fn getNumOfCharsOfLine(self: *const Node, line: usize) !u32 {
        const GetNumOfCharsOfLineCtx = struct {
            total_noc: u32 = 0,
            fn walker(ctx_: *anyopaque, leaf: *const Leaf) WalkResult {
                const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
                ctx.total_noc += leaf.noc;
                if (leaf.eol) return WalkResult.stop;
                return WalkResult.keep_walking;
            }
        };

        if (line > self.weights().bols) return error.LineOutOfBounds;
        var ctx = GetNumOfCharsOfLineCtx{};
        const walk_result = self.walkLine(line, GetNumOfCharsOfLineCtx.walker, &ctx);
        if (walk_result.err) |err| return err;
        return ctx.total_noc;
    }
    test getNumOfCharsOfLine {
        const a = idc_if_it_leaks;
        {
            const root = try Node.fromString(a, "1\n22\n333\n4444", true);
            try eq(1, try root.getNumOfCharsOfLine(0));
            try eq(2, try root.getNumOfCharsOfLine(1));
            try eq(3, try root.getNumOfCharsOfLine(2));
            try eq(4, try root.getNumOfCharsOfLine(3));
        }
        {
            const root = try __inputCharsOneAfterAnother(a, "1\n22\n333\n4444");
            const root_debug_str =
                \\10 4/13/10
                \\  1 B| `1` |E
                \\  9 3/11/9
                \\    1 B| `2`
                \\    8 2/10/8
                \\      1 `2` |E
                \\      7 2/8/7
                \\        1 B| `3`
                \\        6 1/7/6
                \\          1 `3`
                \\          5 1/6/5
                \\            1 `3` |E
                \\            4 1/4/4
                \\              1 B| `4`
                \\              3 0/3/3
                \\                1 `4`
                \\                2 0/2/2
                \\                  1 `4`
                \\                  1 `4`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            try eq(1, try root.getNumOfCharsOfLine(0));
            try eq(2, try root.getNumOfCharsOfLine(1));
            try eq(3, try root.getNumOfCharsOfLine(2));
            try eq(4, try root.getNumOfCharsOfLine(3));
        }
    }

    ///////////////////////////// Flow walk functions

    fn walkLine(self: *const Node, line: usize, f: WalkResult.F, ctx: *anyopaque) WalkResult {
        switch (self.*) {
            .branch => |*branch| {
                const left_bols = branch.left.weights().bols;
                if (line >= left_bols) return branch.right.walkLine(line - left_bols, f, ctx);
                const left = branch.left.walkLine(line, f, ctx);
                const right = if (left.found and left.keep_walking) branch.right.walk(f, ctx) else WalkResult{};
                return WalkResult.merge(left, right);
            },
            .leaf => |*leaf| {
                if (line == 0) {
                    var result = f(ctx, leaf);
                    if (result.err) |_| return result;
                    result.found = true;
                    return result;
                }
                return WalkResult.keep_walking;
            },
        }
    }

    fn walk(self: *const Node, f: WalkResult.F, ctx: *anyopaque) WalkResult {
        switch (self.*) {
            .branch => |*branch| {
                const left = branch.left.walk(f, ctx);
                if (!left.keep_walking) return left;
                const right = branch.right.walk(f, ctx);
                return WalkResult.merge(left, right);
            },
            .leaf => |*l| return f(ctx, l),
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
                \\5 1/5/5
                \\  1 B| `a`
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
                \\4 1/5/5
                \\  3 1/3/3
                \\    1 B| `a`
                \\    2 0/2/2
                \\      1 `b`
                \\      1 `c`
                \\  2 0/2/2
                \\    1 `d`
                \\    1 `e`
            ;
            try eqStr(balanced_root_debug_str, try balanced_root.debugPrint());
        }
    }
    fn __inputCharsOneAfterAnother(a: Allocator, chars: []const u8) !*const Node {
        var root = try Node.fromString(a, "", true);
        for (0..chars.len) |i| root, _, _ = try root.insertChars(a, root.weights().len, chars[i .. i + 1]);
        return root;
    }
    fn __inputCharsOneAfterAnotherAt0Position(a: Allocator, chars: []const u8) !*const Node {
        var root = try Node.fromString(a, "", true);
        for (0..chars.len) |i| root, _, _ = try root.insertChars(a, 0, chars[i .. i + 1]);
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
            should_amend_bols: bool = true,
            first_leaf_bol: ?bool = null,
            last_replacement_eol: ?bool = null,

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
                const end_after_leaf = cx.end_byte >= cx.current_index.* + leaf.buf.len;

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
                if (!cx.should_amend_bols) return WalkMutResult.stop;

                if (cx.last_replacement_eol != null and cx.last_replacement_eol.? == false) {
                    const replace = try Leaf.new(cx.a, leaf.buf, false, leaf.eol);
                    cx.last_replacement_eol = leaf.eol;
                    return WalkMutResult{ .replace = replace };
                }

                if (cx.first_leaf_bol) |bol| {
                    defer cx.should_amend_bols = false;
                    const replace = try Leaf.new(cx.a, leaf.buf, bol, leaf.eol);
                    cx.last_replacement_eol = leaf.eol;
                    return WalkMutResult{ .replace = replace };
                }

                return WalkMutResult.stop;
            }

            fn _removed(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                cx.bytes_deleted += leaf.weights().len;
                if (cx.leaves_encountered == 0) cx.first_leaf_bol = leaf.bol;

                if (cx.num_of_bytes_to_delete == 1 and leaf.bol and !leaf.eol) {
                    cx.should_amend_bols = false;
                    const replace = try Leaf.new(cx.a, "", true, false);
                    cx.last_replacement_eol = false;
                    return WalkMutResult{ .replace = replace };
                }

                if (leaf.eol) {
                    if (leaf.buf.len == 0 and cx.num_of_bytes_to_delete == 1) return WalkMutResult.removed;
                    if (leaf.buf.len == 1 and cx.num_of_bytes_to_delete == 1) {
                        cx.should_amend_bols = false;
                        const replace = try Leaf.new(cx.a, "", leaf.bol, true);
                        cx.last_replacement_eol = true;
                        return WalkMutResult{ .replace = replace };
                    }

                    const eol = if (cx.start_byte + cx.bytes_deleted <= cx.end_byte) false else leaf.eol;
                    const bol = if (cx.leaves_encountered == 0) leaf.bol else false;
                    const replace = try Leaf.new(cx.a, "", bol, eol);
                    cx.last_replacement_eol = eol;
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
                    cx.last_replacement_eol = leaf.eol;
                    return WalkMutResult{ .replace = right_side };
                }

                const right_side_wiped_out = right_side_content.len == 0;
                if (right_side_wiped_out) {
                    const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, leaf.eol);
                    cx.last_replacement_eol = leaf.eol;
                    return WalkMutResult{ .replace = left_side };
                }

                const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, false);
                const right_side = try Leaf.new(cx.a, right_side_content, false, leaf.eol);
                const replace = try Node.new(cx.a, left_side, right_side);
                cx.last_replacement_eol = leaf.eol;
                return WalkMutResult{ .replace = replace };
            }

            fn _leftSide(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                const split_index = cx.start_byte - cx.current_index.*;
                const left_side_content = leaf.buf[0..split_index];
                const left_side = try Leaf.new(cx.a, left_side_content, leaf.bol, false);
                cx.bytes_deleted += leaf.buf.len - left_side_content.len;

                if (leaf.eol) cx.bytes_deleted += 1;

                cx.last_replacement_eol = false;
                return WalkMutResult{ .replace = left_side };
            }

            fn _rightSide(cx: *@This(), leaf: *const Leaf) !WalkMutResult {
                const bol = if (cx.start_byte + cx.bytes_deleted <= cx.current_index.*)
                    if (cx.first_leaf_bol) |bol| bol else false
                else
                    leaf.bol;
                const bytes_left_to_delete = cx.num_of_bytes_to_delete - cx.bytes_deleted;
                const right_side_content = leaf.buf[bytes_left_to_delete..];
                const right_side = try Leaf.new(cx.a, right_side_content, bol, leaf.eol);
                cx.last_replacement_eol = leaf.eol;
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

        const one_two = try Node.new(a, try Leaf.new(a, "1ne", true, false), try Leaf.new(a, "_two", false, false));
        const three_four = try Node.new(a, try Leaf.new(a, "_three", false, false), try Leaf.new(a, "_four", false, true));
        const one_two_three_four = try Node.new(a, one_two, three_four);
        const one_two_three_four_str =
            \\3 1/19/18
            \\  2 1/7/7
            \\    1 B| `1ne`
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
                    \\    1 B| `1ne`
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
                    \\    1 B| `1`
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
                    \\    1 B| `1`
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
                    \\  1 B| `1`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try one_two_three_four.deleteBytes(a, 0, 6);
                const new_root_debug_str =
                    \\3 1/13/12
                    \\  1 B| `o`
                    \\  2 0/12/11
                    \\    1 `_three`
                    \\    1 `_four` |E
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
                \\2 1/11/11
                \\  1 B| `Hello`
                \\  1 `World!`
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
                    \\3 2/15/14
                    \\  1 B| `Hello`
                    \\  2 1/10/9
                    \\    1 `from` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 2);
                const new_root_debug_str =
                    \\3 2/14/13
                    \\  1 B| `Hello`
                    \\  2 1/9/8
                    \\    1 `rom` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 3);
                const new_root_debug_str =
                    \\3 2/13/12
                    \\  1 B| `Hello`
                    \\  2 1/8/7
                    \\    1 `om` |E
                    \\    1 B| `Earth`
                ;
                try eqStr(new_root_debug_str, try new_root.debugPrint());
            }
            {
                const new_root = try root.deleteBytes(a, 5, 4);
                const new_root_debug_str =
                    \\3 2/12/11
                    \\  1 B| `Hello`
                    \\  2 1/7/6
                    \\    1 `m` |E
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
        {
            const root = try Node.fromString(a, "1\n\n22\n\n333", true);
            const root_debug_str =
                \\4 5/10/6
                \\  2 2/3/1
                \\    1 B| `1` |E
                \\    1 B| `` |E
                \\  3 3/7/5
                \\    1 B| `22` |E
                \\    2 2/4/3
                \\      1 B| `` |E
                \\      1 B| `333`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const edit_1 = try root.deleteBytes(a, 1, 1);
            const edit_1_debug_str =
                \\4 4/9/6
                \\  2 1/2/1
                \\    1 B| `1`
                \\    1 `` |E
                \\  3 3/7/5
                \\    1 B| `22` |E
                \\    2 2/4/3
                \\      1 B| `` |E
                \\      1 B| `333`
            ;
            try eqStr(edit_1_debug_str, try edit_1.debugPrint());

            const edit_2 = try edit_1.deleteBytes(a, 1, 1);
            const edit_2_debug_str =
                \\4 3/8/6
                \\  1 B| `1`
                \\  3 2/7/5
                \\    1 `22` |E
                \\    2 2/4/3
                \\      1 B| `` |E
                \\      1 B| `333`
            ;
            try eqStr(edit_2_debug_str, try edit_2.debugPrint());
        }

        {
            const root = try Node.fromString(a, "hello\nworld", true);
            const root_debug_str =
                \\2 2/11/10
                \\  1 B| `hello` |E
                \\  1 B| `world`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const edit_1 = try root.deleteBytes(a, 2, 6);
            const edit_1_debug_str =
                \\2 1/5/5
                \\  1 B| `he`
                \\  1 `rld`
            ;
            try eqStr(edit_1_debug_str, try edit_1.debugPrint());
        }
        {
            const root = try Node.fromString(a, "hello\nworld\nvenus", true);
            const root_debug_str =
                \\3 3/17/15
                \\  1 B| `hello` |E
                \\  2 2/11/10
                \\    1 B| `world` |E
                \\    1 B| `venus`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const edit_1 = try root.deleteBytes(a, 4, 1);
            const edit_1_debug_str =
                \\3 3/16/14
                \\  1 B| `hell` |E
                \\  2 2/11/10
                \\    1 B| `world` |E
                \\    1 B| `venus`
            ;
            try eqStr(edit_1_debug_str, try edit_1.debugPrint());

            const edit_2 = try edit_1.deleteBytes(a, 4, 1);
            const edit_2_debug_str =
                \\3 2/15/14
                \\  1 B| `hell`
                \\  2 1/11/10
                \\    1 `world` |E
                \\    1 B| `venus`
            ;
            try eqStr(edit_2_debug_str, try edit_2.debugPrint());

            const edit_3 = try edit_2.deleteBytes(a, 3, 9);
            const edit_3_debug_str =
                \\3 1/6/6
                \\  1 B| `hel`
                \\  2 0/3/3
                \\    1 ``
                \\    1 `nus`
            ;
            try eqStr(edit_3_debug_str, try edit_3.debugPrint());
        }
        {
            const root = try Node.fromString(a, "a\nb\nc", true);
            const root_debug_str =
                \\3 3/5/3
                \\  1 B| `a` |E
                \\  2 2/3/2
                \\    1 B| `b` |E
                \\    1 B| `c`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const edit_1 = try root.deleteBytes(a, 2, 1);
            const edit_1_debug_str =
                \\3 3/4/2
                \\  1 B| `a` |E
                \\  2 2/2/1
                \\    1 B| `` |E
                \\    1 B| `c`
            ;
            try eqStr(edit_1_debug_str, try edit_1.debugPrint());

            const edit_2 = try edit_1.deleteBytes(a, 2, 1);
            const edit_2_debug_str =
                \\2 2/3/2
                \\  1 B| `a` |E
                \\  1 B| `c`
            ;
            try eqStr(edit_2_debug_str, try edit_2.debugPrint());
        }

        // keep bol
        {
            const root = try Node.fromString(a, "a", true);
            const root_debug_str =
                \\1 B| `a`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const e1 = try root.deleteBytes(a, 0, 1);
            const e1d =
                \\1 B| ``
            ;
            try eqStr(e1d, try e1.debugPrint());
        }
        {
            const root = try Node.fromString(a, "a\nb", true);
            const root_debug_str =
                \\2 2/3/2
                \\  1 B| `a` |E
                \\  1 B| `b`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const e1 = try root.deleteBytes(a, 2, 1);
            const e1d =
                \\2 2/2/1
                \\  1 B| `a` |E
                \\  1 B| ``
            ;
            try eqStr(e1d, try e1.debugPrint());
        }
        {
            const root = try Node.fromString(a, "a\nb\nc", true);
            const root_debug_str =
                \\3 3/5/3
                \\  1 B| `a` |E
                \\  2 2/3/2
                \\    1 B| `b` |E
                \\    1 B| `c`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            const e1 = try root.deleteBytes(a, 2, 1);
            const e1d =
                \\3 3/4/2
                \\  1 B| `a` |E
                \\  2 2/2/1
                \\    1 B| `` |E
                \\    1 B| `c`
            ;
            try eqStr(e1d, try e1.debugPrint());
        }
        {
            const root = try Node.fromString(a, "1\n22\n333\n4444\n55555", true);
            const root_debug_str =
                \\4 5/19/15
                \\  2 2/5/3
                \\    1 B| `1` |E
                \\    1 B| `22` |E
                \\  3 3/14/12
                \\    1 B| `333` |E
                \\    2 2/10/9
                \\      1 B| `4444` |E
                \\      1 B| `55555`
            ;
            try eqStr(root_debug_str, try root.debugPrint());

            std.debug.print("*****************************************************\n", .{});
            const e1 = try root.deleteBytes(a, 3, 6);
            const e1d =
                \\4 3/13/11
                \\  2 2/3/2
                \\    1 B| `1` |E
                \\    1 B| `2`
                \\  3 1/10/9
                \\    1 ``
                \\    2 1/10/9
                \\      1 `4444` |E
                \\      1 B| `55555`
            ;
            try eqStr(e1d, try e1.debugPrint());
        }
    }

    ///////////////////////////// Insert Chars

    const InsertCharsError = error{ OutOfMemory, EmptyStringNotAllowed, InsertIndexOutOfBounds };
    pub fn insertChars(
        self: *const Node,
        a: Allocator,
        start_byte: usize,
        chars: []const u8,
    ) InsertCharsError!struct { *const Node, usize, usize } {
        const InsertCharsCtx = struct {
            a: Allocator,
            buf: []const u8,
            start_byte: usize,
            yep_newline: bool,
            current_index: usize = 0,
            num_of_new_lines: usize = 0,
            last_new_leaf_noc: usize = 0,

            fn walkToInsert(ctx: *@This(), node: *const Node) WalkMutResult {
                if (ctx.current_index > ctx.start_byte) return WalkMutResult.stop;
                switch (node.*) {
                    .branch => |*branch| {
                        const left_end = ctx.current_index + branch.left.weights().len;
                        if (ctx.start_byte < left_end) {
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
                var new_leaves = createLeavesByNewLine(cx.a, cx.buf) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Unexpected => @panic("got Unexpected error from createLeavesByNewLine()"),
                };
                if (new_leaves.len > 1) cx.num_of_new_lines = new_leaves.len - 1;
                if (new_leaves.len > 0) cx.last_new_leaf_noc = new_leaves[new_leaves.len - 1].weights().noc;

                if (cx.yep_newline) cx.num_of_new_lines = 1;

                if (leaf.buf.len == 0) return try _leafBufHasNoText(cx, leaf, new_leaves);

                const insert_at_start = cx.current_index == cx.start_byte;
                if (insert_at_start) return try _insertAtStart(cx, leaf, new_leaves);

                const insert_at_end = cx.current_index + leaf.buf.len == cx.start_byte;
                if (insert_at_end) return try _insertAtEnd(cx, leaf, new_leaves);

                return try _insertInMiddle(cx, leaf, new_leaves);
            }

            fn _leafBufHasNoText(cx: *@This(), leaf: *const Leaf, new_leaves: []Node) !WalkMutResult {
                if (cx.yep_newline) {
                    const left = try Leaf.new(cx.a, "", leaf.bol, true);
                    const right = try Leaf.new(cx.a, "", true, leaf.eol);
                    const replacement = try Node.new(cx.a, left, right);
                    return WalkMutResult{ .replace = replacement };
                }
                if (new_leaves.len == 1) {
                    const replacement = try Leaf.new(cx.a, new_leaves[0].leaf.buf, leaf.bol, leaf.eol);
                    return WalkMutResult{ .replace = replacement };
                }
                new_leaves[0].leaf.bol = leaf.bol;
                const replacement = try mergeLeaves(cx.a, new_leaves);
                return WalkMutResult{ .replace = replacement };
            }

            fn _insertAtStart(cx: *@This(), leaf: *const Leaf, new_leaves: []Node) !WalkMutResult {
                new_leaves[0].leaf.bol = leaf.bol;
                const left = try mergeLeaves(cx.a, new_leaves);

                const right_bol = if (cx.yep_newline) true else false;
                const right = try Leaf.new(cx.a, leaf.buf, right_bol, leaf.eol);

                const replacement = try Node.new(cx.a, left, right);
                return WalkMutResult{ .replace = replacement };
            }

            fn _insertAtEnd(cx: *@This(), leaf: *const Leaf, new_leaves: []Node) !WalkMutResult {
                const left_eol = if (cx.yep_newline) true else false;
                const left = try Leaf.new(cx.a, leaf.buf, leaf.bol, left_eol);

                if (cx.yep_newline) new_leaves[0].leaf.bol = true;
                new_leaves[new_leaves.len - 1].leaf.eol = leaf.eol;
                const right = try mergeLeaves(cx.a, new_leaves);

                const replacement = try Node.new(cx.a, left, right);
                return WalkMutResult{ .replace = replacement };
            }

            fn _insertInMiddle(cx: *@This(), leaf: *const Leaf, new_leaves: []Node) !WalkMutResult {
                const split_index = cx.start_byte - cx.current_index;
                const left_split = leaf.buf[0..split_index];
                const right_split = leaf.buf[split_index..leaf.buf.len];

                var first_eol = false;
                if (cx.buf[0] == '\n') first_eol = true;

                var last_bol = false;
                if (cx.yep_newline) last_bol = true;
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
        if (start_byte > self.weights().len) return error.InsertIndexOutOfBounds;
        const buf = try a.dupe(u8, chars);
        var ctx = InsertCharsCtx{
            .a = a,
            .buf = buf,
            .start_byte = start_byte,
            .yep_newline = eql(u8, buf, "\n"),
        };
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

        // \n at end of Leaf
        {
            const root = try Leaf.new(a, "const", true, false);
            const new_root, _, _ = try root.insertChars(a, 5, "\n");
            const new_root_debug_str =
                \\2 2/6/5
                \\  1 B| `const` |E
                \\  1 B| ``
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(a, "const", true, false);
            const new_root, _, _ = try root.insertChars(a, 0, "\n");
            const new_root_debug_str =
                \\2 2/6/5
                \\  1 B| `` |E
                \\  1 B| `const`
            ;
            try eqStr(new_root_debug_str, try new_root.debugPrint());
        }
        {
            const root = try Leaf.new(a, "const", true, true);
            const new_root, _, _ = try root.insertChars(a, 0, "\n");
            const new_root_debug_str =
                \\2 2/7/5
                \\  1 B| `` |E
                \\  1 B| `const` |E
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
                \\2 2/13/12
                \\  1 B| `const str =` |E
                \\  1 B| `;`
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

        // \n insertions
        {
            var root = try Leaf.new(a, "const", true, false);
            root, _, _ = try root.insertChars(a, 5, "\n");
            const root_dbg_str =
                \\2 2/6/5
                \\  1 B| `const` |E
                \\  1 B| ``
            ;
            try eqStr(root_dbg_str, try root.debugPrint());

            root, _, _ = try root.insertChars(a, 6, "\n");
            const root2_str =
                \\3 3/7/5
                \\  1 B| `const` |E
                \\  2 2/1/0
                \\    1 B| `` |E
                \\    1 B| ``
            ;
            try eqStr(root2_str, try root.debugPrint());

            root, _, _ = try root.insertChars(a, 6, "\n");
            const root3_str =
                \\4 4/8/5
                \\  1 B| `const` |E
                \\  3 3/2/0
                \\    2 2/2/0
                \\      1 B| `` |E
                \\      1 B| `` |E
                \\    1 B| ``
            ;
            try eqStr(root3_str, try root.debugPrint());
        }
        {
            var root = try Node.fromString(a, "one\n\n22", true);
            root, _, _ = try root.insertChars(a, 3, "\n");
            const root_dbg_str =
                \\3 4/8/5
                \\  2 2/5/3
                \\    1 B| `one` |E
                \\    1 B| `` |E
                \\  2 2/3/2
                \\    1 B| `` |E
                \\    1 B| `22`
            ;
            try eqStr(root_dbg_str, try root.debugPrint());
        }
        {
            var root = try Node.fromString(a, "one\n22", true);
            root, _, _ = try root.insertChars(a, 3, "\n");
            const root_dbg_str =
                \\3 3/7/5
                \\  2 2/5/3
                \\    1 B| `one` |E
                \\    1 B| `` |E
                \\  1 B| `22`
            ;
            try eqStr(root_dbg_str, try root.debugPrint());
        }
        {
            var root = try Node.fromString(a, "one\n22", true);
            root, _, _ = try root.insertChars(a, 4, "\n");
            const root_dbg_str =
                \\3 3/7/5
                \\  1 B| `one` |E
                \\  2 2/3/2
                \\    1 B| `` |E
                \\    1 B| `22`
            ;
            try eqStr(root_dbg_str, try root.debugPrint());
        }

        // insert \n at start of document
        {
            var root = try Node.fromString(a, "", true);
            root, _, _ = try root.insertChars(a, 0, "\n");
            const root_dbg_str =
                \\2 2/1/0
                \\  1 B| `` |E
                \\  1 B| ``
            ;
            try eqStr(root_dbg_str, try root.debugPrint());

            root, _, _ = try root.insertChars(a, 0, "\n");
            const root_dbg_str2 =
                \\3 3/2/0
                \\  2 2/2/0
                \\    1 B| `` |E
                \\    1 B| `` |E
                \\  1 B| ``
            ;
            try eqStr(root_dbg_str2, try root.debugPrint());
        }
        {
            var root = try Node.fromString(a, "", true);
            root, _, _ = try root.insertChars(a, 0, "4");
            root, _, _ = try root.insertChars(a, 0, "4");
            root, _, _ = try root.insertChars(a, 0, "4");
            root, _, _ = try root.insertChars(a, 0, "4");
            root, _, _ = try root.insertChars(a, 0, "\n");
            const root_dbg_str =
                \\5 2/5/4
                \\  4 2/4/3
                \\    3 2/3/2
                \\      2 2/2/1
                \\        1 B| `` |E
                \\        1 B| `4`
                \\      1 `4`
                \\    1 `4`
                \\  1 `4`
            ;
            try eqStr(root_dbg_str, try root.debugPrint());
            {
                root, _, _ = try root.insertChars(a, 0, "3");
                const str =
                    \\5 2/6/5
                    \\  4 2/5/4
                    \\    3 2/4/3
                    \\      2 2/3/2
                    \\        1 B| `3` |E
                    \\        1 B| `4`
                    \\      1 `4`
                    \\    1 `4`
                    \\  1 `4`
                ;
                try eqStr(str, try root.debugPrint());
            }
            {
                root, _, _ = try root.insertChars(a, 0, "3");
                const str =
                    \\6 2/7/6
                    \\  5 2/6/5
                    \\    4 2/5/4
                    \\      3 2/4/3
                    \\        2 1/3/2
                    \\          1 B| `3`
                    \\          1 `3` |E
                    \\        1 B| `4`
                    \\      1 `4`
                    \\    1 `4`
                    \\  1 `4`
                ;
                try eqStr(str, try root.debugPrint());
            }
        }

        // insert '\n' in middle of a leaf
        {
            var root = try Node.fromString(a, "hello", true);
            const new_root, _, _ = try root.insertChars(a, 4, "\n");
            const str =
                \\2 2/6/5
                \\  1 B| `hell` |E
                \\  1 B| `o`
            ;
            try eqStr(str, try new_root.debugPrint());
        }

        {
            const source =
                \\const ten = 10;
                \\fn dummy() void {
                \\}
                \\pub var x = 0;
                \\pub var y = 0;
            ;
            var root = try Node.fromString(a, source, true);
            const rootd =
                \\4 5/65/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/31/29
                \\    1 B| `}` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(rootd, try root.debugPrint());

            const e1, _, _ = try root.insertChars(a, try root.getByteOffsetOfPosition(2, 1), "\n");
            const e1d =
                \\4 6/66/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 4/32/29
                \\    2 2/3/1
                \\      1 B| `}` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e1d, try e1.debugPrint());

            const b1 = try e1.balance(a);
            const b1d =
                \\4 6/66/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 4/32/29
                \\    2 2/3/1
                \\      1 B| `}` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b1d, try b1.debugPrint());

            const e2 = try b1.deleteBytes(a, try b1.getByteOffsetOfPosition(2, 1), 1);
            const e2d =
                \\4 5/65/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/31/29
                \\    2 1/2/1
                \\      1 B| `}`
                \\      1 `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e2d, try e2.debugPrint());

            const b2 = try e2.balance(a);
            const b2d =
                \\4 5/65/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/31/29
                \\    2 1/2/1
                \\      1 B| `}`
                \\      1 `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b2d, try b2.debugPrint());

            const e3, _, _ = try b2.insertChars(a, try b2.getByteOffsetOfPosition(2, 1), "\n");
            const e3d =
                \\5 6/66/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  4 4/32/29
                \\    3 2/3/1
                \\      1 B| `}`
                \\      2 1/2/0
                \\        1 `` |E
                \\        1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e3d, try e3.debugPrint());

            const b3 = try e3.balance(a);
            const b3d =
                \\4 6/66/61
                \\  3 3/35/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}`
                \\  3 3/31/28
                \\    2 1/2/0
                \\      1 `` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b3d, try b3.debugPrint());

            const e4 = try b3.deleteBytes(a, try b3.getByteOffsetOfPosition(2, 1), 1);
            const e4d =
                \\4 5/65/61
                \\  3 3/35/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}`
                \\  3 2/30/28
                \\    1 `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e4d, try e4.debugPrint());

            const b4 = try e4.balance(a);
            const b4d =
                \\4 5/65/61
                \\  3 3/35/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}`
                \\  3 2/30/28
                \\    1 `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b4d, try b4.debugPrint());

            const e5, _, _ = try b2.insertChars(a, try b4.getByteOffsetOfPosition(2, 1), "o");
            const e5d =
                \\4 5/66/62
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/32/30
                \\    2 1/3/2
                \\      1 B| `}`
                \\      1 `o` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e5d, try e5.debugPrint());

            const b5 = try e5.balance(a);
            const b5d =
                \\4 5/66/62
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/32/30
                \\    2 1/3/2
                \\      1 B| `}`
                \\      1 `o` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b5d, try b5.debugPrint());

            const e6 = try b5.deleteBytes(a, try b5.getByteOffsetOfPosition(2, 1), 1);
            const e6d =
                \\4 5/65/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/31/29
                \\    2 1/2/1
                \\      1 B| `}`
                \\      1 `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e6d, try e6.debugPrint());
        }

        //////////////////////////////////////////////////////////////////////////////////////////////

        {
            const source =
                \\const ten = 10;
                \\fn dummy() void {
                \\}
                \\pub var x = 0;
                \\pub var y = 0;
            ;
            var root = try Node.fromString(a, source, true);
            const rootd =
                \\4 5/65/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 3/31/29
                \\    1 B| `}` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(rootd, try root.debugPrint());

            const e1, _, _ = try root.insertChars(a, try root.getByteOffsetOfPosition(2, 1), "\n");
            const e1d =
                \\4 6/66/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 4/32/29
                \\    2 2/3/1
                \\      1 B| `}` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e1d, try e1.debugPrint());

            const b1 = try e1.balance(a);
            const b1d =
                \\4 6/66/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  3 4/32/29
                \\    2 2/3/1
                \\      1 B| `}` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b1d, try b1.debugPrint());

            const e2, _, _ = try b1.insertChars(a, try b1.getByteOffsetOfPosition(3, 0), "\n");
            const e2d =
                \\5 7/67/61
                \\  2 2/34/32
                \\    1 B| `const ten = 10;` |E
                \\    1 B| `fn dummy() void {` |E
                \\  4 5/33/29
                \\    3 3/4/1
                \\      1 B| `}` |E
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e2d, try e2.debugPrint());

            const b2 = try e2.balance(a);
            const b2d =
                \\4 7/67/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  3 4/31/28
                \\    2 2/2/0
                \\      1 B| `` |E
                \\      1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b2d, try b2.debugPrint());

            const e3, _, _ = try b2.insertChars(a, try b2.getByteOffsetOfPosition(4, 0), "\n");
            const e3d =
                \\5 8/68/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  4 5/32/28
                \\    3 3/3/0
                \\      1 B| `` |E
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e3d, try e3.debugPrint());

            const b3 = try e3.balance(a);
            const b3d =
                \\5 8/68/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  4 5/32/28
                \\    3 3/3/0
                \\      1 B| `` |E
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b3d, try b3.debugPrint());

            const e4, _, _ = try b3.insertChars(a, try b3.getByteOffsetOfPosition(5, 0), "\n");
            const e4d =
                \\6 9/69/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  5 6/33/28
                \\    4 4/4/0
                \\      1 B| `` |E
                \\      3 3/3/0
                \\        1 B| `` |E
                \\        2 2/2/0
                \\          1 B| `` |E
                \\          1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e4d, try e4.debugPrint());

            const b4 = try e4.balance(a);
            const b4d =
                \\5 9/69/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  4 6/33/28
                \\    3 4/4/0
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(b4d, try b4.debugPrint());

            const e5, _, _ = try b4.insertChars(a, try b4.getByteOffsetOfPosition(6, 0), "\n");
            const e5d =
                \\6 10/70/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  5 7/34/28
                \\    4 5/5/0
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\      3 3/3/0
                \\        1 B| `` |E
                \\        2 2/2/0
                \\          1 B| `` |E
                \\          1 B| `` |E
                \\    2 2/29/28
                \\      1 B| `pub var x = 0;` |E
                \\      1 B| `pub var y = 0;`
            ;
            try eqStr(e5d, try e5.debugPrint());

            const b5 = try e5.balance(a);
            const b5d =
                \\5 10/70/61
                \\  3 3/36/33
                \\    2 2/34/32
                \\      1 B| `const ten = 10;` |E
                \\      1 B| `fn dummy() void {` |E
                \\    1 B| `}` |E
                \\  4 7/34/28
                \\    3 3/3/0
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\      1 B| `` |E
                \\    3 4/31/28
                \\      2 2/2/0
                \\        1 B| `` |E
                \\        1 B| `` |E
                \\      2 2/29/28
                \\        1 B| `pub var x = 0;` |E
                \\        1 B| `pub var y = 0;`
            ;
            try eqStr(b5d, try b5.debugPrint());
        }
    }

    ///////////////////////////// Get Byte Offset from Position

    const GetByteOffsetOfPositionError = error{ OutOfMemory, LineOutOfBounds, ColOutOfBounds };
    pub fn getByteOffsetOfPosition(self: *const Node, line: usize, col: usize) GetByteOffsetOfPositionError!usize {
        const GetByteOffsetCtx = struct {
            target_line: usize,
            target_col: usize,

            byte_offset: usize = 0,
            current_line: usize = 0,
            current_col: usize = 0,
            should_stop: bool = false,
            encountered_bol: bool = false,

            fn walk(cx: *@This(), node: *const Node) WalkResult {
                if (cx.should_stop) return WalkResult.stop;

                switch (node.*) {
                    .branch => |branch| {
                        const left_bols_end = cx.current_line + branch.left.weights().bols;

                        var left = WalkResult.keep_walking;
                        if (cx.current_line == cx.target_line or cx.target_line < left_bols_end) {
                            left = cx.walk(branch.left);
                        }

                        if (cx.current_line < cx.target_line) {
                            cx.byte_offset += branch.left.weights().len;
                        }

                        cx.current_line = left_bols_end;

                        const right = cx.walk(branch.right);
                        return WalkResult.merge(left, right);
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

        if (line > self.weights().bols) return error.LineOutOfBounds;
        var ctx = GetByteOffsetCtx{ .target_line = line, .target_col = col };
        if (ctx.walk(self).err) |err| return err else {
            if (ctx.current_col < col) return error.ColOutOfBounds;
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
        {
            const source = "1\n22\n333\n4444";
            const root = try __inputCharsOneAfterAnother(a, source);
            const root_debug_str =
                \\10 4/13/10
                \\  1 B| `1` |E
                \\  9 3/11/9
                \\    1 B| `2`
                \\    8 2/10/8
                \\      1 `2` |E
                \\      7 2/8/7
                \\        1 B| `3`
                \\        6 1/7/6
                \\          1 `3`
                \\          5 1/6/5
                \\            1 `3` |E
                \\            4 1/4/4
                \\              1 B| `4`
                \\              3 0/3/3
                \\                1 `4`
                \\                2 0/2/2
                \\                  1 `4`
                \\                  1 `4`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            try eq(0, root.getByteOffsetOfPosition(0, 0));
            try eq(1, root.getByteOffsetOfPosition(0, 1));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 2));
            try eq(2, root.getByteOffsetOfPosition(1, 0));
            try eq(3, root.getByteOffsetOfPosition(1, 1));
            try eq(4, root.getByteOffsetOfPosition(1, 2));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(1, 3));
            try eq(5, root.getByteOffsetOfPosition(2, 0));
            try eq(6, root.getByteOffsetOfPosition(2, 1));
            try eq(7, root.getByteOffsetOfPosition(2, 2));
            try eq(8, root.getByteOffsetOfPosition(2, 3));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(2, 4));
        }
        {
            const reverse_input_sequence = "4444\n333\n22\n1";
            const root = try __inputCharsOneAfterAnotherAt0Position(a, reverse_input_sequence);
            const root_debug_str =
                \\10 4/13/10
                \\  9 4/12/9
                \\    8 4/11/8
                \\      7 4/10/7
                \\        6 3/9/6
                \\          5 3/7/5
                \\            4 3/6/4
                \\              3 2/5/3
                \\                2 2/3/2
                \\                  1 B| `1` |E
                \\                  1 B| `2`
                \\                1 `2` |E
                \\              1 B| `3`
                \\            1 `3`
                \\          1 `3` |E
                \\        1 B| `4`
                \\      1 `4`
                \\    1 `4`
                \\  1 `4`
            ;
            try eqStr(root_debug_str, try root.debugPrint());
            try eq(0, root.getByteOffsetOfPosition(0, 0));
            try eq(1, root.getByteOffsetOfPosition(0, 1));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(0, 2));
            try eq(2, root.getByteOffsetOfPosition(1, 0));
            try eq(3, root.getByteOffsetOfPosition(1, 1));
            try eq(4, root.getByteOffsetOfPosition(1, 2));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(1, 3));
            try eq(5, root.getByteOffsetOfPosition(2, 0));
            try eq(6, root.getByteOffsetOfPosition(2, 1));
            try eq(7, root.getByteOffsetOfPosition(2, 2));
            try eq(8, root.getByteOffsetOfPosition(2, 3));
            try shouldErr(error.ColOutOfBounds, root.getByteOffsetOfPosition(2, 4));
        }
    }

    ///////////////////////////// Node Info

    pub fn weights(self: *const Node) Weights {
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
                \\4 1/4/4
                \\  1 B| `a`
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
