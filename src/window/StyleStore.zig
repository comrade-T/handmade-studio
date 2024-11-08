const StyleStore = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const FontStore = @import("FontStore");
const ColorschemeStore = @import("ColorschemeStore");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
fonts: FontMap = undefined,
colorschemes: ColorschemeMap = undefined,

const StyleKey = struct {
    query_id: u16,
    capture_id: u16,
    styleset_id: u16,
};
const FontMap = std.AutoArrayHashMapUnmanaged(StyleKey, *const FontStore.Font);
const ColorschemeMap = std.AutoArrayHashMapUnmanaged(StyleKey, *const ColorschemeStore.Colorscheme);

pub fn init(a: Allocator) !StyleStore {
    var self = StyleStore{ .a = a };

    self.fonts = FontMap{};
    self.colorschemes = ColorschemeMap{};

    return self;
}

pub fn deinit(self: *@This()) void {
    self.fonts.deinit(self.a);
    self.colorschemes.deinit(self.a);
}

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
    var ss = try StyleStore.init(testing_allocator);
    defer ss.deinit();
}
