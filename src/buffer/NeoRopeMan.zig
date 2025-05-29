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

const NeoRopeMan = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const rcr = @import("RcRope.zig");
pub const RcNode = rcr.RcNode;
pub const EditRange = rcr.EditRange;
pub const EditPoint = rcr.EditPoint;

//////////////////////////////////////////////////////////////////////////////////////////////

arena: std.heap.ArenaAllocator,
root: RcNode = undefined,
pending: ListOfRoots = .{},
history: ListOfRoots = .{},

const ListOfRoots = std.ArrayListUnmanaged(RcNode);
pub const InitFrom = enum { string, file };

pub fn initFrom(a: Allocator, from: InitFrom, source: []const u8) !NeoRopeMan {
    var ropeman = try NeoRopeMan.init(a);
    switch (from) {
        .string => ropeman.root = try rcr.Node.fromString(ropeman.a, &ropeman.arena, source),
        .file => ropeman.root = try rcr.Node.fromFile(ropeman.a, &ropeman.arena, source),
    }

    try ropeman.history.append(ropeman.root);

    return ropeman;
}

pub fn deinit(self: *@This()) void {
    rcr.freeRcNodes(self.a, self.pending.items);
    self.pending.deinit();
    rcr.freeRcNodes(self.a, self.history.items);
    self.history.deinit();
    self.arena.deinit();
}

fn init(a: Allocator) !NeoRopeMan {
    return NeoRopeMan{ .arena = std.heap.ArenaAllocator.init(a) };
}

//////////////////////////////////////////////////////////////////////////////////////////////

test "size matters" {
    try std.testing.expectEqual(32, @sizeOf(std.heap.ArenaAllocator));
    try std.testing.expectEqual(24, @sizeOf(ListOfRoots));
    try std.testing.expectEqual(8, @sizeOf(RcNode));
}
