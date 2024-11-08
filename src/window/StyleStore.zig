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

pub fn init(a: Allocator) !StyleStore {
    return StyleStore{
        .a = a,
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
