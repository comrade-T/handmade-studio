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

pub fn addFontSizeStyle(self: *@This(), key: StyleKey, font_size: f32) !void {
    assert(font_size > 0);
    const fs = if (font_size <= 0) 1 else font_size;
    try self.font_sizes.put(self.a, key, fs);
}

pub fn addColorschemeStyle(self: *@This(), key: StyleKey, colorscheme_index: u16) !void {
    try self.colorschemes.put(self.a, key, @intCast(colorscheme_index));
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn getFont(self: *const @This(), key: StyleKey) ?*const FontStore.Font {
    const index = self.fonts.get(key) orelse return null;
    assert(index < self.font_store.map.values().len);
    return &self.font_store.map.values()[index];
}

pub fn getFontSize(self: *const @This(), key: StyleKey) ?f32 {
    return self.font_sizes.get(key);
}

pub fn getColorscheme(self: *const @This(), key: StyleKey) ?*const FontStore.Font {
    const index = self.colorschemes.get(key) orelse return null;
    assert(index < self.colorscheme_store.map.values().len);
    return &self.colorscheme_store.map.values()[index];
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn createMockFontStore(a: Allocator) !FontStore {
    var font_store = try FontStore.init(a);
    try font_store.addNewFont(null, "Test", 40, 30);
    const f = font_store.getDefaultFont() orelse unreachable;
    for (32..126) |i| try f.addGlyph(a, @intCast(i), .{ .offsetX = 0, .width = 1.1e1, .advanceX = 15 });
    return font_store;
}

pub fn createStyleStoreForTesting(a: Allocator) !*StyleStore {
    const font_store = try a.create(FontStore);
    font_store.* = try createMockFontStore(a);

    const colorscheme_store = try a.create(ColorschemeStore);
    colorscheme_store.* = try ColorschemeStore.init(a);
    try colorscheme_store.initializeNightflyColorscheme();

    const style_store = try a.create(StyleStore);
    style_store.* = StyleStore.init(a, font_store, colorscheme_store);

    return style_store;
}

pub fn freeTestStyleStore(a: Allocator, style_store: *StyleStore) void {
    style_store.font_store.deinit();
    a.destroy(style_store.font_store);

    style_store.colorscheme_store.deinit();
    a.destroy(style_store.colorscheme_store);

    style_store.deinit();
    a.destroy(style_store);
}

//////////////////////////////////////////////////////////////////////////////////////////////

test StyleStore {
    // setup font_store
    var font_store = try FontStore.init(testing_allocator);
    defer font_store.deinit();

    try font_store.addNewFont(null, "Meslo", 40);
    try font_store.addNewFont(null, "Inter", 80);

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
