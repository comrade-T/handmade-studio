const TextBox = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const MappingCouncil = @import("input_processor").MappingCouncil;

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn init(council: *MappingCouncil) !TextBox {
    var self = TextBox{};
    try self.mapStuffs();
    return self;
}

pub fn deinit(self: *@This()) !void {
    // TODO:
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn mapStuffs(self: *@This()) !void {
    // TODO:
}

//////////////////////////////////////////////////////////////////////////////////////////////
