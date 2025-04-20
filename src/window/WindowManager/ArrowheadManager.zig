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
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const RenderMall = @import("RenderMall");

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

pub fn getElder(self: *const @This(), index_: u32) ?*const Arrowhead {
    assert(self.elders.items.len > 0);
    const index: usize = @intCast(index_);
    if (index == 0) return null;
    if (index >= self.elders.items.len) return &self.elders.items[self.elders.items.len - 1];
    return &self.elders.items[index];
}

// pub fn replaceElderWithDisciple(self: *@This(), index: usize) !void {
//     if (index >= self.elders.items.len) return;
//     self.elders.items[index] = self.disciple;
// }

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

    pub fn render(self: *const @This(), start_x: f32, start_y: f32, end_x: f32, end_y: f32, mall: *const RenderMall) void {
        if (self.shouldNotRender()) return;

        const angle = std.math.atan2(end_y - start_y, end_x - start_x);
        const left_angle = angle + (self.angle * std.math.pi) / 180.0;
        const right_angle = angle - (self.angle * std.math.pi) / 180.0;

        const left_x = end_x - self.line_length * @cos(left_angle);
        const left_y = end_y - self.line_length * @sin(left_angle);
        const right_x = end_x - self.line_length * @cos(right_angle);
        const right_y = end_y - self.line_length * @sin(right_angle);

        mall.rcb.drawLine(end_x, end_y, left_x, left_y, self.thickness, self.color);
        mall.rcb.drawLine(end_x, end_y, right_x, right_y, self.thickness, self.color);
    }

    fn shouldNotRender(self: *const @This()) bool {
        return self.thickness == 0;
    }
};

const default_arrowheads = [_]Arrowhead{
    .{ .thickness = 0 }, // 0

    .{},
    .{ .line_length = 20, .angle = 20 },
    .{ .line_length = 20, .angle = 30, .thickness = 2 },
    .{ .thickness = 0 },
};
