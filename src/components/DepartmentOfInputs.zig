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

const ip = @import("input_processor");
const MappingCouncil = ip.MappingCouncil;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
mall: *const RenderMall,
council: *MappingCouncil,

inputs: InputMap = .{},

pub fn addInput(self: *@This(), name: []const u8, callback: Input.Callback) !bool {
    if (self.inputs.contains(name)) return false;

    const input = try Input.create(self.a, self.mall, name, self.council, callback);
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
    const input = self.inputs.get(name) orelse return false;
    input.destroy(self.a, name, self.council);
    return self.inputs.swapRemove(name);
}

pub fn showInput(self: *@This(), name: []const u8) !bool {
    const input = self.inputs.get(name) orelse return false;
    input.win.open();
    try self.council.addActiveContext(name);
    return true;
}

pub fn hideInput(self: *@This(), name: []const u8) !bool {
    const input = self.inputs.get(name) orelse return false;
    input.win.close();
    try self.council.removeActiveContext(name);
    return true;
}

pub fn deinit(self: *@This()) void {
    for (self.inputs.keys(), 0..) |context_id, i| {
        self.inputs.values()[i].destroy(self.a, context_id, self.council);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Input

const InputMap = std.StringArrayHashMapUnmanaged(*Input);

const Input = struct {
    mall: *const RenderMall,
    source: *WindowSource,
    win: *Window,
    callback: Callback,

    const Callback = struct {
        f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!void,
        ctx: *anyopaque,
    };

    fn create(a: Allocator, mall: *const RenderMall, context_id: []const u8, callback: Callback, council: *MappingCouncil) !*@This() {
        const self = try a.create(@This());
        const source = try WindowSource.create(a, .string, "", null);

        const screen_rect = mall.getScreenRect();

        self.* = Input{
            .mall = mall,
            .source = source,
            .win = try Window.create(a, null, source, .{
                .pos = .{
                    .x = screen_rect.x + screen_rect.width / 2,
                    .y = screen_rect.y + screen_rect.height / 2,
                },
                .bordered = true,
                .padding = .{ .bottom = 10, .left = 10, .top = 10, .right = 10 },
            }, mall),
            .callback = callback,
        };

        self.mapKeys(context_id, council);
        return self;
    }

    fn insertChars(self: *@This(), a: Allocator, chars: []const u8, mall: *const RenderMall) !void {
        const results = try self.source.insertChars(a, chars, self.window.cursor_manager) orelse return;
        defer a.free(results);
        try self.window.processEditResult(null, null, results, mall);
    }

    fn mapKeys(input: *@This(), cid: []const u8, c: *MappingCouncil) !void {
        try c.mapInsertCharacters(&.{cid}, input, InsertCharsCb.init);
    }

    const InsertCharsCb = struct {
        chars: []const u8,
        target: *Input,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.insertChars(self.chars);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*Input, @ptrCast(@alignCast(ctx)));
            self.* = .{ .chars = chars, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };

    fn destroy(self: *@This(), a: Allocator, context_id: []const u8, c: *MappingCouncil) void {
        self.source.destroy();
        self.win.destroy(null, null);
        assert(c.unmapEntireContext(context_id));
        a.destroy(self);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////
