const std = @import("std");
const ts = @import("ts.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const CustomNode = union(enum) {
    branch: Branch,
    leaf: Leaf,

    pub fn new(aa: Allocator, tsnode: ts.b.Node) !CustomNode {
        return try Branch.new(aa, tsnode);
    }

    const Branch = struct {
        tsnode: ts.b.Node,
        children: []CustomNode = undefined,
        weights: u16 = 0,

        fn new(aa: Allocator, tsnode: ts.b.Node) !CustomNode {
            var branch = Branch{ .tsnode = tsnode };

            var list = ArrayList(CustomNode).init(aa);
            var iter = tsnode.childIterator();
            while (iter.next()) |ts_child| {
                const child = if (ts_child.getChildCount() == 0)
                    try Leaf.new(ts_child)
                else
                    try Branch.new(aa, ts_child);
                try list.append(child);
            }
            branch.children = try list.toOwnedSlice();

            branch.calculateWeights();

            return CustomNode{ .branch = branch };
        }

        fn calculateWeights(self: *@This()) void {
            self.weights = 0;
            for (self.children) |child| {
                switch (child) {
                    .branch => |branch| self.weights += branch.weights,
                    .leaf => self.weights += 1,
                }
            }
        }
    };

    const Leaf = struct {
        tsnode: ts.b.Node,

        fn new(tsnode: ts.b.Node) !CustomNode {
            return CustomNode{ .leaf = Leaf{ .tsnode = tsnode } };
        }
    };
};
