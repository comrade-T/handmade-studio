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

const DepartmentOfInputs = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const RenderMall = @import("RenderMall");
const WindowSource = @import("WindowSource");
const Window = @import("Window");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
mall: *const RenderMall,
inputs: InputMap = .{},

pub fn addInput(self: *@This(), name: []const u8) !bool {
    if (self.inputs.contains(name)) return false;

    const input = try Input.create(self.a, self.mall);
    try self.inputs.put(self.a, name, input);
    return true;
}

pub fn render(self: *@This()) void {
    for (self.inputs.values()) |input| {
        if (input.win.closed) continue;
        input.win.render(false, self.mall, null);
    }
}

pub fn removeInput(self: *@This(), name: []const u8) bool {
    return self.inputs.swapRemove(name);
}

pub fn showInput(self: *@This(), name: []const u8) bool {
    const input = self.inputs.get(name) orelse return false;
    input.win.open();
    return true;
}

pub fn hideInput(self: *@This(), name: []const u8) bool {
    const input = self.inputs.get(name) orelse return false;
    input.win.close();
    return true;
}

pub fn deinit(self: *@This()) void {
    for (self.inputs.values()) |input| input.destroy(self.a);
}

////////////////////////////////////////////////////////////////////////////////////////////// Input

const InputMap = std.StringArrayHashMapUnmanaged(*Input);

const Input = struct {
    source: *WindowSource,
    win: *Window,

    fn create(a: Allocator, mall: *const RenderMall) !*@This() {
        const self = try a.create(@This());
        const source = try WindowSource.create(a, .string, "", null);

        const screen_rect = mall.getScreenRect();

        self.* = DepartmentOfInputs{
            .source = source,
            .win = try Window.create(a, null, source, .{
                .pos = .{
                    .x = screen_rect.x + screen_rect.width / 2,
                    .y = screen_rect.y + screen_rect.height / 2,
                },
                .bordered = true,
                .padding = .{ .bottom = 10, .left = 10, .top = 10, .right = 10 },
            }, mall),
        };
        return self;
    }

    fn destroy(self: *@This(), a: Allocator) void {
        self.source.destroy();
        self.win.destroy(null, null);
        a.destroy(self);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////
