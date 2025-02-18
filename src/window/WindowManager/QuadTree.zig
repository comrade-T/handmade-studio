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

const WindowManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn contains(self: Rect, other: Rect) bool {
        return other.x >= self.x and other.x + other.width <= self.x + self.width and
            other.y >= self.y and other.y + other.height <= self.y + self.height;
    }

    fn intersects(self: Rect, other: Rect) bool {
        return !(other.x > self.x + self.width or
            other.x + other.width < self.x or
            other.y > self.y + self.height or
            other.y + other.height < self.y);
    }
};

const QUADTREE_MAX_DEPTH = 16;

pub fn QuadTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const ItemList = std.ArrayListUnmanaged(T);

        depth: u8,
        rect: Rect,

        item_list: ItemList = ItemList{},
        ne: ?*Self = null,
        nw: ?*Self = null,
        se: ?*Self = null,
        sw: ?*Self = null,

        pub fn create(a: Allocator, rect: Rect, depth: u8) !*Self {
            const self = try a.create(Self);
            self.* = .{ .rect = rect, .depth = depth };
            return self;
        }

        pub fn destroy(self: *@This(), a: Allocator) void {
            defer a.destroy(self);
            self.item_list.deinit(a);
            if (self.ne) |ne| ne.destroy(a);
            if (self.nw) |nw| nw.destroy(a);
            if (self.se) |se| se.destroy(a);
            if (self.sw) |sw| sw.destroy(a);
        }

        pub fn insert(self: *@This(), a: Allocator, item: T, item_rect: Rect) !void {
            if (self.depth + 1 < QUADTREE_MAX_DEPTH) {
                const x = self.rect.x;
                const y = self.rect.y;
                const w = self.rect.width / 2;
                const h = self.rect.height / 2;

                const ne_rect = Rect{ .x = x + w, .y = y, .width = w, .height = h };
                const nw_rect = Rect{ .x = x, .y = y, .width = w, .height = h };
                const se_rect = Rect{ .x = x + w, .y = y + h, .width = w, .height = h };
                const sw_rect = Rect{ .x = x, .y = y + h, .width = w, .height = h };

                if (ne_rect.contains(item_rect)) {
                    if (self.ne == null) self.ne = try Self.create(a, ne_rect, self.depth + 1);
                    try self.ne.?.insert(a, item, item_rect);
                    return;
                }
                if (nw_rect.contains(item_rect)) {
                    if (self.nw == null) self.nw = try Self.create(a, nw_rect, self.depth + 1);
                    try self.nw.?.insert(a, item, item_rect);
                    return;
                }
                if (se_rect.contains(item_rect)) {
                    if (self.se == null) self.se = try Self.create(a, se_rect, self.depth + 1);
                    try self.se.?.insert(a, item, item_rect);
                    return;
                }
                if (sw_rect.contains(item_rect)) {
                    if (self.sw == null) self.se = try Self.create(a, sw_rect, self.depth + 1);
                    try self.sw.?.insert(a, item, item_rect);
                    return;
                }
            }

            try self.item_list.append(a, item);
        }
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

test QuadTree {
    const a = testing_allocator;

    var tree = try QuadTree(u8).create(a, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0);
    defer tree.destroy(a);

    try eq(0, tree.item_list.items.len);

    {
        try tree.insert(a, 69, .{ .x = 10, .y = 10, .width = 10, .height = 10 });

        try eq(0, tree.depth);
        try eq(0, tree.item_list.items.len);
        try eq(null, tree.ne);
        try eq(null, tree.se);
        try eq(null, tree.sw);

        const d0_nw = tree.nw.?;
        try eq(Rect{ .x = 0, .y = 0, .width = 50, .height = 50 }, d0_nw.rect);
        try eq(1, d0_nw.depth);
        try eq(0, d0_nw.item_list.items.len);
        try eq(null, d0_nw.ne);
        try eq(null, d0_nw.se);
        try eq(null, d0_nw.sw);

        const d1_nw = d0_nw.nw.?;
        try eq(Rect{ .x = 0, .y = 0, .width = 25, .height = 25 }, d1_nw.rect);
        try eq(2, d1_nw.depth);
        try eq(1, d1_nw.item_list.items.len);
        try eq(null, d1_nw.nw);
        try eq(null, d1_nw.ne);
        try eq(null, d1_nw.se);
        try eq(null, d1_nw.sw);
        try eq(69, d1_nw.item_list.items[0]);
    }
}
