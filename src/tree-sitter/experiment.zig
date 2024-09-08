const std = @import("std");
const ts = @import("ts.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const CustomNode = union(enum) {
    branch: *Branch,
    leaf: Leaf,

    pub fn new(a: Allocator, tsnode: ts.b.Node) !*CustomNode {
        return try Branch.new(a, tsnode);
    }

    const Branch = struct {
        a: Allocator,
        tsnode: ts.b.Node,
        children: ArrayList(*CustomNode),

        fn new(a: Allocator, tsnode: ts.b.Node) !*CustomNode {
            const branch = try a.create(Branch);
            branch.* = .{
                .a = a,
                .tsnode = tsnode,
                .children = ArrayList(*CustomNode).init(a),
            };
            var iter = tsnode.childIterator();
            while (iter.next()) |ts_child| {
                const child = if (ts_child.getChildCount() == 0)
                    try Leaf.new(a, ts_child)
                else
                    try @This().new(a, ts_child);
                try branch.children.append(child);
            }
            const node = try a.create(CustomNode);
            node.* = .{ .branch = branch };
            return node;
        }
    };

    const Leaf = struct {
        tsnode: ts.b.Node,

        fn new(a: Allocator, tsnode: ts.b.Node) !*CustomNode {
            const node = try a.create(CustomNode);
            node.* = .{ .leaf = Leaf{ .tsnode = tsnode } };
            return node;
        }
    };
};
