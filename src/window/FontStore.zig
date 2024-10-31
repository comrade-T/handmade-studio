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

const FontStore = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
map: FontMap,
default_idx: usize = 0,

pub fn init(a: Allocator) !FontStore {
    return FontStore{ .a = a, .map = FontMap{} };
}

pub fn deinit(self: *@This()) void {
    for (self.map.values()) |*font| font.glyph_map.deinit(self.a);
    self.map.deinit(self.a);
}

pub fn getDefaultFont(self: *@This()) ?*Font {
    const fonts = self.map.values();
    if (fonts.len == 0) return null;
    assert(self.default_idx < fonts.len);
    return if (self.default_idx < fonts.len) &fonts[self.default_idx] else null;
}

pub fn addNewFont(self: *@This(), font_name: []const u8, base_size: f32) !void {
    try self.map.put(self.a, font_name, Font{ .base_size = base_size, .glyph_map = Font.GlyphMap{} });
}

pub fn addGlyphDataToFont(self: *@This(), font_name: []const u8, code_point: i32, data: Font.GlyphData) !void {
    assert(self.map.getPtr(font_name) != null);
    var font = self.map.getPtr(font_name) orelse return;
    try font.glyph_map.put(self.a, code_point, data);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const FontMap = std.StringArrayHashMapUnmanaged(Font);

pub const Font = struct {
    const GlyphMap = std.AutoHashMapUnmanaged(i32, GlyphData);

    pub const GlyphData = struct {
        advanceX: f32,
        offsetX: f32,
        width: f32,
    };

    base_size: f32,
    glyph_map: GlyphMap,
};
