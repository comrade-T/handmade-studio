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

const ArrowheadManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

elders: ArrowheadList,
disciple: Arrowhead = .{},

const ArrowheadList = std.ArrayList(Arrowhead);

pub fn init(a: Allocator) !ArrowheadManager {
    var list = ArrowheadList.init(a);
    try list.appendSlice(&default_arrowheads);
    return ArrowheadManager{ .elders = list };
}

pub fn deinit(self: *@This()) void {
    self.elders.deinit();
}

pub fn getElder(self: *@This(), index: usize) *Arrowhead {
    std.debug.assert(self.elders.items.len > 0);
    if (index >= self.elders.items.len) return &self.elders.items[index];
    return &self.elders.items[self.elders.items.len - 1];
}

pub fn replaceElderWithDisciple(self: *@This(), index: usize) !void {
    if (index >= self.elders.items.len) return;
    self.elders.items[index] = self.disciple;
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Arrowhead = struct {
    thickness: f32 = 1,
    line_length: f32 = 10,
    angle: f32 = 10,
    color: u32 = 0xffffffff,

    pub fn add(self: *@This(), other: Arrowhead) void {
        self.thickness += other.thickness;
        self.line_length += other.line_length;
        self.angle += other.angle;
    }
};

const default_arrowheads = [_]Arrowhead{
    .{ .line_length = 20, .angle = 20 },
    .{ .line_length = 20, .angle = 30, .thickness = 2 },
};
