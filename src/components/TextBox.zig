const TextBox = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const ip = @import("input_processor");
const MappingCouncil = ip.MappingCouncil;
const RopeMan = @import("RopeMan");
const CursorManager = @import("CursorManager");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
ropeman: RopeMan,
curman: *CursorManager,

pub fn init(a: Allocator, council: *MappingCouncil, initial_needle: []const u8) !TextBox {
    var self = TextBox{
        .a = a,
        .ropeman = try RopeMan.initFrom(a, .string, initial_needle),
        .curman = try CursorManager.create(a),
    };
    try self.mapStuffs(council);
    return self;
}

pub fn deinit(self: *@This()) void {
    self.ropeman.deinit();
    self.curman.destroy();
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert Chars

fn insertChars(self: *@This(), chars: []const u8) !void {
    const input_points = try self.curman.produceCursorPoints(self.a);
    defer self.a.free(input_points);
    const output_points = try self.ropeman.insertChars(self.a, chars, input_points);
    defer self.a.free(output_points);
}

const TextBoxInsertCharsCb = struct {
    chars: []const u8,
    target: *TextBox,
    fn f(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        try self.target.insertChars(self.chars);
    }
    fn init(allocator: std.mem.Allocator, ctx: *anyopaque, chars: []const u8) !ip.Callback {
        const self = try allocator.create(@This());
        const target = @as(*TextBox, @ptrCast(@alignCast(ctx)));
        self.* = .{ .chars = chars, .target = target };
        return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Movement

fn moveCursorLeft(ctx: *anyopaque) !void {
    const self = @as(*TextBox, @ptrCast(@alignCast(ctx)));
    self.curman.moveLeft(1, &self.ropeman);
}

fn moveCursorRight(ctx: *anyopaque) !void {
    const self = @as(*TextBox, @ptrCast(@alignCast(ctx)));
    self.curman.moveRight(1, &self.ropeman);
}

////////////////////////////////////////////////////////////////////////////////////////////// mapping

fn mapStuffs(self: *@This(), council: *MappingCouncil) !void {
    try council.map("text_box_insert", &.{ .escape, .h }, .{ .f = moveCursorLeft, .ctx = self });
    try council.map("text_box_insert", &.{ .escape, .l }, .{ .f = moveCursorRight, .ctx = self });
    try council.mapInsertCharacters(&.{"text_box_insert"}, self, TextBoxInsertCharsCb.init);
}

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();
    var text_box = try TextBox.init(testing_allocator, council, "");
    defer text_box.deinit();
}
