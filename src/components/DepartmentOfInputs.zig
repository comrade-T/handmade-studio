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
mall: *RenderMall,
council: *MappingCouncil,

inputs: InputMap = .{},

pub fn addInput(self: *@This(), name: []const u8, win_opts: Window.SpawnOptions, callbacks: Input.Callbacks) !bool {
    if (self.inputs.contains(name)) return false;

    const input = try Input.create(self.a, win_opts, self, name, callbacks);
    try self.inputs.put(self.a, name, input);
    return true;
}

pub fn render(self: *@This()) void {
    for (self.inputs.values()) |input| {
        if (input.win.closed) continue;
        input.win.render(true, self.mall, null);
    }
}

pub fn removeInput(self: *@This(), name: []const u8) bool {
    const input = self.inputs.get(name) orelse return false;
    input.destroy(name, self.council);
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

pub fn replaceInputContent(self: *@This(), input_name: []const u8, new_content: []const u8) !bool {
    const input = self.inputs.get(input_name) orelse return false;

    {
        const last_linenr = input.source.buf.ropeman.getNumOfLines() - 1;
        const del_points = try input.source.buf.ropeman.deleteRanges(self.a, &.{.{
            .start = .{ .line = 0, .col = 0 },
            .end = .{
                .line = last_linenr,
                .col = input.source.buf.ropeman.getNumOfCharsInLine(last_linenr),
            },
        }});
        self.a.free(del_points);

        const insert_points = try input.source.buf.ropeman.insertChars(self.a, new_content, &.{.{ .line = 0, .col = 0 }});
        self.a.free(insert_points);

        input.win.cursor_manager.mainCursor().setActiveAnchor(input.win.cursor_manager, 0, 0);
        input.win.cursor_manager.moveToEndOfLine(&input.source.buf.ropeman);
        input.win.cursor_manager.enterAFTERInsertMode(&input.source.buf.ropeman);
    }

    return true;
}

pub fn deinit(self: *@This()) void {
    for (self.inputs.keys(), 0..) |context_id, i| {
        self.inputs.values()[i].destroy(context_id, self.council);
    }
    self.inputs.deinit(self.a);
}

////////////////////////////////////////////////////////////////////////////////////////////// Input

const InputMap = std.StringArrayHashMapUnmanaged(*Input);

const Input = struct {
    a: Allocator,
    mall: *const RenderMall,
    source: *WindowSource,
    win: *Window,
    callbacks: Callbacks,

    const Callback = struct {
        f: *const fn (ctx: *anyopaque, input_result: []const u8) anyerror!void,
        ctx: *anyopaque,
    };

    const Callbacks = struct {
        onUpdate: ?Callback = null,
        onConfirm: ?Callback = null,
        onCancel: ?Callback = null,
    };

    fn create(a: Allocator, win_opts: Window.SpawnOptions, doi: *const DepartmentOfInputs, context_id: []const u8, callbacks: Callbacks) !*@This() {
        const self = try a.create(@This());
        const source = try WindowSource.create(a, .string, "", null);

        self.* = Input{
            .a = a,
            .mall = doi.mall,
            .source = source,
            .win = try Window.create(a, null, source, win_opts, doi.mall),
            .callbacks = callbacks,
        };

        try self.mapKeys(context_id, doi.council);
        self.win.close();
        return self;
    }

    fn mapKeys(input: *@This(), cid: []const u8, c: *MappingCouncil) !void {
        try c.mapInsertCharacters(&.{cid}, input, InsertCharsCb.init);
        try c.map(cid, &.{.backspace}, .{ .f = backspace, .ctx = input });
        try c.map(cid, &.{.enter}, .{ .f = confirm, .ctx = input });
        try c.map(cid, &.{.escape}, .{ .f = cancel, .ctx = input });
    }

    fn triggerCallback(self: *@This(), kind: enum { update, confirm, cancel }) !void {
        const field = switch (kind) {
            .update => self.callbacks.onUpdate,
            .confirm => self.callbacks.onConfirm,
            .cancel => self.callbacks.onCancel,
        };
        const cb = field orelse return;
        const contents = try self.source.buf.ropeman.toString(self.a, .lf);
        defer self.a.free(contents);
        try cb.f(cb.ctx, contents);
    }

    fn insertChars(self: *@This(), chars: []const u8, mall: *const RenderMall) !void {
        const results = try self.source.insertChars(self.a, chars, self.win.cursor_manager) orelse return;
        defer self.a.free(results);
        try self.win.processEditResult(null, null, results, mall);
        try self.triggerCallback(.update);
    }

    fn backspace(ctx: *anyopaque) !void {
        const self = @as(*Input, @ptrCast(@alignCast(ctx)));
        const result = try self.source.deleteRanges(self.a, self.win.cursor_manager, .backspace) orelse return;
        defer self.a.free(result);
        try self.win.processEditResult(null, null, result, self.mall);
        try self.triggerCallback(.update);
    }

    fn confirm(ctx: *anyopaque) !void {
        const self = @as(*Input, @ptrCast(@alignCast(ctx)));
        try self.triggerCallback(.confirm);
    }

    fn cancel(ctx: *anyopaque) !void {
        const self = @as(*Input, @ptrCast(@alignCast(ctx)));
        try self.triggerCallback(.cancel);
    }

    const InsertCharsCb = struct {
        chars: []const u8,
        target: *Input,
        fn f(ctx: *anyopaque) !void {
            const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
            try self.target.insertChars(self.chars, self.target.mall);
        }
        pub fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !ip.Callback {
            const self = try allocator.create(@This());
            const target = @as(*Input, @ptrCast(@alignCast(ctx)));
            self.* = .{ .chars = chars, .target = target };
            return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
        }
    };

    fn destroy(self: *@This(), context_id: []const u8, c: *MappingCouncil) void {
        self.source.destroy();
        self.win.destroy(null, null);
        assert(c.unmapEntireContext(context_id));
        self.a.destroy(self);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////
