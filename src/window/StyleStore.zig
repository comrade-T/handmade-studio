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

const StyleStore = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;

const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

font_store: *FontStore,
colorscheme_store: *ColorschemeStore,

fonts: FontMap = undefined,
font_sizes: FontSizeMap = undefined,
colorschemes: ColorschemeMap = undefined,

const FontMap = std.AutoArrayHashMapUnmanaged(StyleKey, u16);
const FontSizeMap = std.AutoArrayHashMapUnmanaged(StyleKey, f32);
const ColorschemeMap = std.AutoArrayHashMapUnmanaged(StyleKey, u16);
pub const StyleKey = struct {
    query_id: u16,
    capture_id: u16,
    styleset_id: u16,
};

pub fn init(a: Allocator, font_store: *FontStore, colorscheme_store: *ColorschemeStore) StyleStore {
    return StyleStore{
        .a = a,

        .font_store = font_store,
        .colorscheme_store = colorscheme_store,

        .fonts = FontMap{},
        .font_sizes = FontSizeMap{},
        .colorschemes = ColorschemeMap{},
    };
}

pub fn deinit(self: *@This()) void {
    self.fonts.deinit(self.a);
    self.font_sizes.deinit(self.a);
    self.colorschemes.deinit(self.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn addFontStyle(self: *@This(), key: StyleKey, font_index: u16) !void {
    try self.fonts.put(self.a, key, @intCast(font_index));
}

pub fn addColorschemeStyle(self: *@This(), key: StyleKey, colorscheme_index: u16) !void {
    try self.colorschemes.put(self.a, key, @intCast(colorscheme_index));
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn getFont(self: *@This(), key: StyleKey) ?*const FontStore.Font {
    const index = self.fonts.get(key) orelse return null;
    assert(index < self.font_store.map.values().len);
    return &self.font_store.map.values()[index];
}

pub fn getColorscheme(self: *@This(), key: StyleKey) ?*const FontStore.Font {
    const index = self.colorschemes.get(key) orelse return null;
    assert(index < self.colorscheme_store.map.values().len);
    return &self.colorscheme_store.map.values()[index];
}

//////////////////////////////////////////////////////////////////////////////////////////////

test StyleStore {
    // setup font_store
    var font_store = try FontStore.init(testing_allocator);
    defer font_store.deinit();

    var dummy_font: void = {};
    try font_store.addNewFont(&dummy_font, "Meslo", 40);
    try font_store.addNewFont(&dummy_font, "Inter", 80);

    // setup colorscheme_store
    var colorscheme_store = try ColorschemeStore.init(testing_allocator);
    defer colorscheme_store.deinit();
    try colorscheme_store.initializeNightflyColorscheme();

    // style_store
    var style_store = StyleStore.init(testing_allocator, &font_store, &colorscheme_store);
    defer style_store.deinit();

    // addFontStyle()
    try style_store.addFontStyle(.{ .query_id = 0, .capture_id = 0, .styleset_id = 0 }, 0);
    try style_store.addFontStyle(.{ .query_id = 0, .capture_id = 0, .styleset_id = 1 }, 1);

    { // getFont()
        const meslo = style_store.getFont(.{ .query_id = 0, .capture_id = 0, .styleset_id = 0 });
        try eq(40, meslo.?.base_size);

        const inter = style_store.getFont(.{ .query_id = 0, .capture_id = 0, .styleset_id = 1 });
        try eq(80, inter.?.base_size);

        const not_exist = style_store.getFont(.{ .query_id = 0, .capture_id = 0, .styleset_id = 100 });
        try eq(null, not_exist);
    }
}
