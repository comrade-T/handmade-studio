const std = @import("std");
const ts = @import("ts.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const CustomNode = union(enum) {
    branch: Branch,
    leaf: Leaf,

    pub fn new(aa: Allocator, tsnode: ts.b.Node) !*CustomNode {
        return try Branch.new(aa, null, tsnode);
    }

    const Branch = struct {
        tsnode: ts.b.Node,
        parent: ?*CustomNode,
        children: []*CustomNode = undefined,
        weights: u16 = 0,
        depth: u16 = 1,
        expanded: bool = false,

        fn new(aa: Allocator, parent: ?*CustomNode, tsnode: ts.b.Node) !*CustomNode {
            const node = try aa.create(CustomNode);
            var branch = Branch{ .tsnode = tsnode, .parent = parent };

            var list = ArrayList(*CustomNode).init(aa);
            var iter = tsnode.childIterator();
            while (iter.next()) |ts_child| {
                const child = if (ts_child.getChildCount() == 0)
                    try Leaf.new(aa, ts_child)
                else
                    try Branch.new(aa, node, ts_child);
                try list.append(child);
            }
            branch.children = try list.toOwnedSlice();

            branch.calculateWeights();

            node.* = .{ .branch = branch };
            return node;
        }

        fn calculateWeights(self: *@This()) void {
            self.weights = 0;
            for (self.children) |child| {
                switch (child.*) {
                    .branch => |branch| {
                        if (branch.expanded) {
                            self.weights += branch.weights;
                        } else {
                            self.weights += 1;
                        }
                        self.depth = @max(self.depth, branch.depth);
                    },
                    .leaf => self.weights += 1,
                }
            }
            self.depth += 1;
        }

        fn calculateWeightsRecursivelyUpwards(self: *@This()) void {
            self.calculateWeights();
            if (self.parent) |parent| parent.branch.calculateWeightsRecursivelyUpwards();
        }

        pub fn toggle(self: *@This()) void {
            self.expanded = !self.expanded;
            self.calculateWeightsRecursivelyUpwards();
        }
    };

    const Leaf = struct {
        tsnode: ts.b.Node,

        fn new(aa: Allocator, tsnode: ts.b.Node) !*CustomNode {
            const node = try aa.create(CustomNode);
            node.* = .{ .leaf = Leaf{ .tsnode = tsnode } };
            return node;
        }
    };
};
