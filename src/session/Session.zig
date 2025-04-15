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

const Session = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const Canvas = @import("Canvas.zig");
const WindowManager = Canvas.WindowManager;
const LangHub = WindowManager.LangHub;
const RenderMall = WindowManager.RenderMall;
const NotificationLine = @import("NotificationLine");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
lang_hub: *LangHub,
mall: *RenderMall,
nl: *NotificationLine,

active_index: ?usize = null,
canvases: std.ArrayListUnmanaged(*Canvas) = .{},

pub fn newCanvas(self: *@This()) !*Canvas {
    const new_canvas = try Canvas.create(self.a, self.lang_hub, self.mall, self.nl);
    try self.canvases.append(self.a, new_canvas);
    self.active_index = self.canvases.items.len - 1;
    return new_canvas;
}

pub fn newCanvasFromFile(self: *@This(), path: []const u8) !void {
    const new_canvas = try self.newCanvas();
    try new_canvas.loadFromFile(path);
}

pub fn deinit(self: *@This()) void {
    for (self.canvases.items) |*canvas| canvas.destroy(self.a);
    self.canvases.deinit(self.a);
}
