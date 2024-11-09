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

const Window = @This();
const std = @import("std");
const ztracy = @import("ztracy");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

pub const LangSuite = @import("LangSuite");
pub const WindowSource = @import("WindowSource");
pub const FontStore = @import("FontStore");
pub const ColorschemeStore = @import("ColorschemeStore");
pub const StyleStore = @import("StyleStore");

const WindowCache = @import("WindowCache.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
attr: Attributes,
ws: *WindowSource,
rcb: ?*const RenderCallbacks,
cached: WindowCache = undefined,
defaults: Defaults,

// experimental
subscribed_style_sets: SubscribedStyleSets,

const SubscribedStyleSets = std.ArrayListUnmanaged(u16);

pub fn create(a: Allocator, ws: *WindowSource, opts: SpawnOptions, style_store: *const StyleStore) !*Window {
    var self = try a.create(@This());
    self.* = .{
        .a = a,
        .ws = ws,
        .attr = .{
            .pos = opts.pos,
            .padding = if (opts.padding) |p| p else Attributes.Padding{},
            .bounds = if (opts.bounds) |b| b else Attributes.Bounds{},
            .bounded = if (opts.bounds) |_| true else false,
        },
        .rcb = opts.render_callbacks,
        .defaults = Defaults{},
        .subscribed_style_sets = SubscribedStyleSets{},
    };
    self.cached = try WindowCache.init(self.a, self, style_store);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.cached.deinit(self.a);
    self.subscribed_style_sets.deinit(self.a);
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

// pub fn render(self: *@This(), supermarket: Supermarket, view: ScreenView) void {
//     const zone = ztracy.ZoneNC(@src(), "Window.render()", 0x00AAFF);
//     defer zone.End();
//
//     assert(self.rcb != null);
//     const rcb = self.rcb orelse return;
//
//     const font = supermarket.font_store.getDefaultFont() orelse unreachable;
//     const font_size = self.defaults.font_size;
//     const default_glyph_data = font.glyph_map.get('?') orelse unreachable; // TODO: get data from default Raylib font
//
//     const colorscheme = supermarket.colorscheme_store.getDefaultColorscheme() orelse unreachable;
//
//     var chars_rendered: i64 = 0;
//     defer ztracy.PlotI("chars_rendered", chars_rendered);
//
//     /////////////////////////////
//
//     if (self.attr.pos.x > view.end.x) return;
//     if (self.attr.pos.y > view.end.y) return;
//
//     if (self.attr.pos.x + self.cached.width < view.start.x) return;
//     if (self.attr.pos.y + self.cached.height < view.start.y) return;
//
//     var x: f32 = self.attr.pos.x;
//     var y: f32 = self.attr.pos.y;
//
//     for (0..self.ws.buf.ropeman.getNumOfLines()) |linenr| {
//         defer x = self.attr.pos.x;
//         defer y += font_size;
//
//         if (y > view.end.y) return;
//         if (x + self.cached.lines.items[linenr].width < view.start.x) continue;
//         if (y + self.cached.lines.items[linenr].height < view.start.y) continue;
//
//         var iter = WindowSource.LineIterator.init(self.ws, linenr) catch continue;
//         while (iter.next(self.ws.cap_list.items[linenr])) |result| {
//             const width = calculateGlyphWidth(font, font_size, result, default_glyph_data);
//             defer x += width;
//
//             if (x > view.end.x) break;
//             if (x + width < view.start.x) continue;
//
//             var color = self.defaults.color;
//
//             var i: usize = result.ids.len;
//             while (i > 0) {
//                 i -= 1;
//                 const ids = result.ids[i];
//                 const group_name = self.ws.ls.?.queries.values()[ids.query_id].query.getCaptureNameForId(ids.capture_id);
//                 if (colorscheme.get(group_name)) |c| {
//                     color = c;
//                     break;
//                 }
//             }
//
//             rcb.drawCodePoint(font, result.code_point, x, y, font_size, color);
//             chars_rendered += 1;
//         }
//     }
// }

////////////////////////////////////////////////////////////////////////////////////////////// Types

const Defaults = struct {
    font_size: f32 = 40,
    color: u32 = 0xF5F5F5F5,
};

const SpawnOptions = struct {
    pos: Attributes.Position = .{},
    bounds: ?Attributes.Bounds = null,
    padding: ?Attributes.Padding = null,

    render_callbacks: ?*const RenderCallbacks = null,
};

const Attributes = struct {
    pos: Position,
    padding: Padding,
    bounds: Bounds,
    bounded: bool,

    const Position = struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    const Bounds = struct {
        width: f32 = 400,
        height: f32 = 400,
        offset: Offset = .{},

        const Offset = struct {
            x: f32 = 0,
            y: f32 = 0,
        };
    };

    const Padding = struct {
        top: f32 = 0,
        right: f32 = 0,
        bottom: f32 = 0,
        left: f32 = 0,
    };
};

////////////////////////////////////////////////////////////////////////////////////////////// Render Callbacks

pub const RenderCallbacks = struct {
    drawCodePoint: *const fn (font: *const FontStore.Font, code_point: u21, x: f32, y: f32, font_size: f32, color: u32) void,
};

const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};

////////////////////////////////////////////////////////////////////////////////////////////// Reference for Testing

test {
    std.testing.refAllDeclsRecursive(WindowCache);
}
