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

const ColorschemeStore = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const assert = std.debug.assert;

const Colorscheme = std.StringArrayHashMapUnmanaged(u32);
const ColorschemeMap = std.StringArrayHashMapUnmanaged(Colorscheme);

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
map: ColorschemeMap,
default_idx: usize = 0,

pub fn init(a: Allocator) !ColorschemeStore {
    return ColorschemeStore{ .a = a, .map = ColorschemeMap{} };
}

pub fn deinit(self: *@This()) void {
    for (self.map.values()) |*colorscheme| colorscheme.deinit(self.a);
    self.map.deinit(self.a);
}

pub fn setDefaultColorscheme(self: *@This(), key: []const u8) bool {
    if (self.map.getIndex(key)) |idx| {
        self.default_idx = idx;
        return true;
    }
    return false;
}

pub fn getDefaultColorscheme(self: *@This()) ?*Colorscheme {
    const colorschemes = self.map.values();
    if (colorschemes.len == 0) return null;
    assert(self.default_idx < colorschemes.len);
    return if (self.default_idx < colorschemes.len) &colorschemes[self.default_idx] else null;
}

test getDefaultColorscheme {
    var store = try ColorschemeStore.init(testing_allocator);
    defer store.deinit();

    try eq(null, store.getDefaultColorscheme());

    try store.initializeNightflyColorscheme();
    try eq(@intFromEnum(Nightfly.watermelon), store.getDefaultColorscheme().?.get("boolean").?);
}

////////////////////////////////////////////////////////////////////////////////////////////// Nightfly

pub fn initializeNightflyColorscheme(self: *@This()) !void {
    var map = Colorscheme{};

    try map.put(self.a, "keyword", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "keyword.modifier", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "keyword.function", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "keyword.operator", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "keyword.return", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "attribute", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "type.qualifier", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "conditional", @intFromEnum(Nightfly.violet));
    try map.put(self.a, "repeat", @intFromEnum(Nightfly.violet));

    try map.put(self.a, "type", @intFromEnum(Nightfly.emerald));
    try map.put(self.a, "type.builtin", @intFromEnum(Nightfly.emerald));

    try map.put(self.a, "function", @intFromEnum(Nightfly.blue));
    try map.put(self.a, "function.builtin", @intFromEnum(Nightfly.blue));
    try map.put(self.a, "field", @intFromEnum(Nightfly.lavender));
    try map.put(self.a, "string", @intFromEnum(Nightfly.peach));
    try map.put(self.a, "comment", @intFromEnum(Nightfly.grey_blue));
    try map.put(self.a, "constant.builtin", @intFromEnum(Nightfly.green));
    try map.put(self.a, "parameter", @intFromEnum(Nightfly.orchid));

    try map.put(self.a, "include", @intFromEnum(Nightfly.red));
    try map.put(self.a, "boolean", @intFromEnum(Nightfly.watermelon));
    try map.put(self.a, "operator", @intFromEnum(Nightfly.watermelon));
    try map.put(self.a, "number", @intFromEnum(Nightfly.orange));

    try map.put(self.a, "variable", @intFromEnum(Nightfly.white));
    try map.put(self.a, "punctuation.bracket", @intFromEnum(Nightfly.white));
    try map.put(self.a, "punctuation.delimiter", @intFromEnum(Nightfly.white));

    try self.map.put(self.a, "Nightfly", map);
}

test initializeNightflyColorscheme {
    var store = try ColorschemeStore.init(testing_allocator);
    defer store.deinit();

    try store.initializeNightflyColorscheme();
    try eq(1, store.map.values().len);
    try eq(@intFromEnum(Nightfly.watermelon), store.map.get("Nightfly").?.get("boolean").?);
}

const Nightfly = enum(u32) {
    none = 0x000000ff,
    black = 0x011627ff,
    white = 0xc3ccdcff,
    black_blue = 0x081e2fff,
    dark_blue = 0x092236ff,
    deep_blue = 0x0e293fff,
    slate_blue = 0x2c3043ff,
    pickle_blue = 0x38507aff,
    cello_blue = 0x1f4462ff,
    regal_blue = 0x1d3b53ff,
    steel_blue = 0x4b6479ff,
    grey_blue = 0x7c8f8fff,
    cadet_blue = 0xa1aab8ff,
    ash_blue = 0xacb4c2ff,
    white_blue = 0xd6deebff,
    yellow = 0xe3d18aff,
    peach = 0xffcb8bff,
    tan = 0xecc48dff,
    orange = 0xf78c6cff,
    orchid = 0xe39aa6ff,
    red = 0xfc514eff,
    watermelon = 0xff5874ff,
    purple = 0xae81ffff,
    violet = 0xc792eaff,
    lavender = 0xb0b2f4ff,
    blue = 0x82aaffff,
    malibu = 0x87bcffff,
    turquoise = 0x7fdbcaff,
    emerald = 0x21c7a8ff,
    green = 0xa1cd5eff,
    cyan_blue = 0x296596ff,
    bay_blue = 0x24567fff,
    kashmir_blue = 0x4d618eff,
    plant_green = 0x2a4e57ff,
};
