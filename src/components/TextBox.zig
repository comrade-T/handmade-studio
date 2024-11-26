const TextBox = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const MappingCouncil = @import("input_processor").MappingCouncil;
const RopeMan = @import("RopeMan");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
ropeman: RopeMan,

pub fn init(a: Allocator, council: *MappingCouncil, initial_needle: []const u8) !TextBox {
    var self = TextBox{
        .a = a,
        .ropeman = try RopeMan.initFrom(a, .string, initial_needle),
    };
    try self.mapStuffs(council);
    return self;
}

pub fn deinit(self: *@This()) void {
    self.ropeman.deinit();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn mapStuffs(self: *@This(), council: *MappingCouncil) !void {
    _ = self;
    _ = council;
}

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
    var council = try MappingCouncil.init(testing_allocator);
    defer council.deinit();
    var text_box = try TextBox.init(testing_allocator, council, "");
    defer text_box.deinit();
}
