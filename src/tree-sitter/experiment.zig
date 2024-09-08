const std = @import("std");
const ts = @import("ts.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Node = ts.b.Node;

pub const CustomStructure = struct {
    a: Allocator,
    node: Node,
    children: ArrayList(*@This()),

    pub fn new(a: Allocator, node: Node) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .node = node,
            .children = ArrayList(*@This()).init(a),
        };
        var iter = node.childIterator();
        while (iter.next()) |child_node| {
            const child = try @This().new(a, child_node);
            try self.children.append(child);
        }
        return self;
    }
};
