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

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn contains(self: Rect, other: Rect) bool {
        return other.x >= self.x and other.x + other.width <= self.x + self.width and
            other.y >= self.y and other.y + other.height <= self.y + self.height;
    }

    fn overlaps(self: Rect, other: Rect) bool {
        return !(other.x > self.x + self.width or
            other.x + other.width < self.x or
            other.y > self.y + self.height or
            other.y + other.height < self.y);
    }

    fn print(self: Rect) void {
        std.debug.print("Rect --> x: {d} | y: {d} | w: {d} | h: {d}\n", .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        });
    }
};

const QUADTREE_MAX_DEPTH = 16;

pub fn QuadTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const ItemMap = std.AutoHashMapUnmanaged(*T, void);

        depth: u8,
        rect: Rect,

        item_map: ItemMap = ItemMap{},
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
            self.item_map.deinit(a);
            if (self.ne) |ne| ne.destroy(a);
            if (self.nw) |nw| nw.destroy(a);
            if (self.se) |se| se.destroy(a);
            if (self.sw) |sw| sw.destroy(a);
        }

        pub fn insert(self: *@This(), a: Allocator, item: *T, item_rect: Rect) !void {
            const new_depth = self.depth + 1;
            if (new_depth < QUADTREE_MAX_DEPTH) {
                const ne_rect, const nw_rect, const se_rect, const sw_rect = self.getQuadrons();
                if (ne_rect.contains(item_rect)) {
                    if (self.ne == null) self.ne = try Self.create(a, ne_rect, new_depth);
                    try self.ne.?.insert(a, item, item_rect);
                    return;
                }
                if (nw_rect.contains(item_rect)) {
                    if (self.nw == null) self.nw = try Self.create(a, nw_rect, new_depth);
                    try self.nw.?.insert(a, item, item_rect);
                    return;
                }
                if (se_rect.contains(item_rect)) {
                    if (self.se == null) self.se = try Self.create(a, se_rect, new_depth);
                    try self.se.?.insert(a, item, item_rect);
                    return;
                }
                if (sw_rect.contains(item_rect)) {
                    if (self.sw == null) self.sw = try Self.create(a, sw_rect, new_depth);
                    try self.sw.?.insert(a, item, item_rect);
                    return;
                }
            }

            try self.item_map.put(a, item, {});
        }

        pub const RemoveResult = struct {
            removed: bool,
            is_now_empty: bool,
        };

        pub fn remove(self: *@This(), a: Allocator, item: *T, item_rect: Rect) RemoveResult {
            var remove_result: RemoveResult = .{ .removed = false, .is_now_empty = false };

            blk: {
                if (self.item_map.contains(item)) {
                    remove_result.removed = self.item_map.remove(item);
                    break :blk;
                }

                const ne_rect, const nw_rect, const se_rect, const sw_rect = self.getQuadrons();
                if (self.ne) |ne| if (ne_rect.contains(item_rect)) {
                    remove_result = ne.remove(a, item, item_rect);
                    if (remove_result.is_now_empty) {
                        ne.destroy(a);
                        self.ne = null;
                    }
                    break :blk;
                };
                if (self.nw) |nw| if (nw_rect.contains(item_rect)) {
                    remove_result = nw.remove(a, item, item_rect);
                    if (remove_result.is_now_empty) {
                        nw.destroy(a);
                        self.nw = null;
                    }
                    break :blk;
                };
                if (self.se) |se| if (se_rect.contains(item_rect)) {
                    remove_result = se.remove(a, item, item_rect);
                    if (remove_result.is_now_empty) {
                        se.destroy(a);
                        self.se = null;
                    }
                    break :blk;
                };
                if (self.sw) |sw| if (sw_rect.contains(item_rect)) {
                    remove_result = sw.remove(a, item, item_rect);
                    if (remove_result.is_now_empty) {
                        sw.destroy(a);
                        self.sw = null;
                    }
                    break :blk;
                };
            }

            return RemoveResult{
                .removed = remove_result.removed,
                .is_now_empty = self.item_map.count() == 0,
            };
        }

        pub fn query(self: *@This(), query_rect: Rect, result: *ArrayList(*T)) !void {
            if (!self.rect.overlaps(query_rect)) return;

            var iter = self.item_map.iterator();
            while (iter.next()) |entry| {
                try result.append(entry.key_ptr.*);
            }

            if (self.ne) |ne| try ne.query(query_rect, result);
            if (self.nw) |nw| try nw.query(query_rect, result);
            if (self.se) |se| try se.query(query_rect, result);
            if (self.sw) |sw| try sw.query(query_rect, result);
        }

        fn getQuadrons(self: *const @This()) struct { Rect, Rect, Rect, Rect } {
            const x = self.rect.x;
            const y = self.rect.y;
            const w = self.rect.width / 2;
            const h = self.rect.height / 2;

            const ne_rect = Rect{ .x = x + w, .y = y, .width = w, .height = h };
            const nw_rect = Rect{ .x = x, .y = y, .width = w, .height = h };
            const se_rect = Rect{ .x = x + w, .y = y + h, .width = w, .height = h };
            const sw_rect = Rect{ .x = x, .y = y + h, .width = w, .height = h };
            return .{ ne_rect, nw_rect, se_rect, sw_rect };
        }
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

test "QuadTree.insert()" {
    const a = testing_allocator;
    var tree = try QuadTree(u8).create(a, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0);
    defer tree.destroy(a);

    try eq(0, tree.item_map.count());

    {
        var item: u8 = 69;
        try tree.insert(a, &item, .{ .x = 10, .y = 10, .width = 10, .height = 10 });

        try eq(0, tree.depth);
        try eq(0, tree.item_map.count());
        try eq(null, tree.ne);
        try eq(null, tree.se);
        try eq(null, tree.sw);

        const d0_nw = tree.nw.?;
        try eq(Rect{ .x = 0, .y = 0, .width = 50, .height = 50 }, d0_nw.rect);
        try eq(1, d0_nw.depth);
        try eq(0, d0_nw.item_map.count());
        try eq(null, d0_nw.ne);
        try eq(null, d0_nw.se);
        try eq(null, d0_nw.sw);

        const d1_nw = d0_nw.nw.?;
        try eq(Rect{ .x = 0, .y = 0, .width = 25, .height = 25 }, d1_nw.rect);
        try eq(2, d1_nw.depth);
        try eq(1, d1_nw.item_map.count());
        try eq(null, d1_nw.nw);
        try eq(null, d1_nw.ne);
        try eq(null, d1_nw.se);
        try eq(null, d1_nw.sw);
        try eq(true, d1_nw.item_map.contains(&item));
    }
}

test "QuadTree.remove()" {
    const a = testing_allocator;
    var tree = try QuadTree(u8).create(a, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0);
    defer tree.destroy(a);

    {
        var item: u8 = 69;
        try tree.insert(a, &item, .{ .x = 10, .y = 10, .width = 10, .height = 10 });

        const remove_result = tree.remove(a, &item, .{ .x = 10, .y = 10, .width = 10, .height = 10 });
        try eq(QuadTree(u8).RemoveResult{ .removed = true, .is_now_empty = true }, remove_result);

        try eq(null, tree.nw);
        try eq(null, tree.ne);
        try eq(null, tree.se);
        try eq(null, tree.sw);
    }
}

test "QuadTree.query()" {
    const a = testing_allocator;
    var tree = try QuadTree(u8).create(a, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0);
    defer tree.destroy(a);

    var item_1: u8 = 69;
    const item_1_rect = Rect{ .x = 10, .y = 10, .width = 10, .height = 10 };
    // 1 item
    {
        try tree.insert(a, &item_1, item_1_rect);

        // not match
        {
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = -100, .y = -100, .width = 5, .height = 5 }, &list);
            try eq(0, list.items.len);
        }

        // matches
        {
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 0, .y = 0, .width = 5, .height = 5 }, &list);
            try eq(1, list.items.len);
            try eq(&item_1, list.items[0]);
        }
        {
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, &list);
            try eq(1, list.items.len);
            try eq(&item_1, list.items[0]);
        }
    }

    var item_2: u8 = 222;
    const item_2_rect = Rect{ .x = 80, .y = 80, .width = 10, .height = 10 };
    // 2 items
    {
        try tree.insert(a, &item_2, item_2_rect);

        // not match
        {
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 200, .y = 200, .width = 5, .height = 5 }, &list);
            try eq(0, list.items.len);
        }

        // matches
        { // only 1st match
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 0, .y = 0, .width = 5, .height = 5 }, &list);
            try eq(1, list.items.len);
            try eq(&item_1, list.items[0]);
        }
        { // both matches
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, &list);
            try eq(2, list.items.len);
            try eq(&item_1, list.items[0]);
            try eq(&item_2, list.items[1]);
        }
    }

    ///////////////////////////// remove test

    const remove_1_result = tree.remove(a, &item_1, item_1_rect);
    try eq(QuadTree(u8).RemoveResult{ .removed = true, .is_now_empty = true }, remove_1_result); // `is_now_empty` is `true` cuz the root itself doesn't contain items (but its child does).

    try eq(null, tree.nw);
    try eq(null, tree.ne);
    try eq(null, tree.sw);
    try eq(false, tree.se == null);

    { // "only 1st match" before no longer match
        var list = ArrayList(*u8).init(testing_allocator);
        defer list.deinit();

        try tree.query(.{ .x = 0, .y = 0, .width = 5, .height = 5 }, &list);
        try eq(0, list.items.len);
    }
    { // only match 2 now
        var list = ArrayList(*u8).init(testing_allocator);
        defer list.deinit();

        try tree.query(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, &list);
        try eq(1, list.items.len);
        try eq(&item_2, list.items[0]);
    }

    // 2nd removal
    const remove_2_result = tree.remove(a, &item_2, item_2_rect);
    try eq(QuadTree(u8).RemoveResult{ .removed = true, .is_now_empty = true }, remove_2_result);
    try eq(null, tree.nw);
    try eq(null, tree.ne);
    try eq(null, tree.sw);
    try eq(null, tree.se);
}

test "QuadTree.query - pt. 2" {
    const a = testing_allocator;
    const QUADTREE_WIDTH = 2_000_000;
    var tree = try QuadTree(u8).create(a, .{
        .x = -QUADTREE_WIDTH / 2,
        .y = -QUADTREE_WIDTH / 2,
        .width = QUADTREE_WIDTH,
        .height = QUADTREE_WIDTH,
    }, 0);
    defer tree.destroy(a);

    var item_1: u8 = 111;
    const item_1_rect = Rect{ .x = 1700, .y = -120, .width = 456, .height = 80 };
    {
        try tree.insert(a, &item_1, item_1_rect);

        // not match
        {
            var list = ArrayList(*u8).init(testing_allocator);
            defer list.deinit();

            try tree.query(.{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, &list);
            try eq(0, list.items.len);
        }
    }
}
