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

const NotificationLine = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const code_point = @import("code_point");
const RenderMall = @import("RenderMall");
const ip = @import("input_processor");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
mall: *const RenderMall,

latest_change: i64 = 0,
y_offset: f32 = 0,
font_size: f32 = 30,
text_color: u32 = 0xffffffff,
visible: bool = false,
message: ?[]const u8 = null,

const MINIMUM_DISPLAY_TIME = 200;

pub fn deinit(self: *@This()) void {
    self.clear();
}

pub fn setMessage(self: *@This(), msg: []const u8) !void {
    self.clear();
    self.message = try self.a.dupe(u8, msg);
    self.latest_change = std.time.milliTimestamp();
}

pub fn render(self: *@This()) void {
    const message = self.message orelse return;
    self.mall.printMessage(message, self.font_size, self.text_color, self.y_offset, 0x000000FF);
}

pub fn clearIfDurationMet(self: *@This()) void {
    if (self.isReadyToBeCleared()) self.clear();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn clear(self: *@This()) void {
    if (self.message == null) return;
    self.a.free(self.message.?);
    self.message = null;
}

fn isReadyToBeCleared(self: *const @This()) bool {
    return std.time.milliTimestamp() - self.latest_change > MINIMUM_DISPLAY_TIME;
}
