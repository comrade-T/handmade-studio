const std = @import("std");

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const Window = struct {
    pub fn insertChars(chars: []const u8) void {
        std.debug.print("Window insertChars!! {s}\n", .{chars});
    }

    pub fn doCustomStuffs(trigger: []const u8) void {
        std.debug.print("Window doing custom stuffs due to trigger!! {s}\n", .{trigger});
    }
};

test {
    std.testing.refAllDeclsRecursive(Window);
}
