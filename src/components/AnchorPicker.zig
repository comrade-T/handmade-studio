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

const AnchorPicker = @This();
const std = @import("std");

const InfoCallbacks = @import("RenderMall").InfoCallbacks;

//////////////////////////////////////////////////////////////////////////////////////////////

icb: InfoCallbacks,
target_anchor: Anchor = .{},
current_anchor: Anchor = .{},

pub fn init(icb: InfoCallbacks) AnchorPicker {
    var self = AnchorPicker{ .icb = icb };
    self.center();
    return self;
}

pub fn center(self: *@This()) void {
    const width, const height = self.icb.getScreenWidthHeight();
    self.target_anchor = .{ .x = width / 2, .y = height / 2 };
}

pub fn percentage(self: *@This(), x_percent: f32, y_percent: f32) void {
    const width, const height = self.icb.getScreenWidthHeight();
    self.target_anchor = .{ .x = width * x_percent / 100, .y = height * y_percent / 100 };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const Anchor = struct {
    x: f32 = 0,
    y: f32 = 0,
};
