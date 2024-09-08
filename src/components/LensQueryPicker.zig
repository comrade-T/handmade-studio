const std = @import("std");
const Allocator = std.mem.Allocator;

const thing = std.StaticStringMap([]const u8).initComptime(.{
    .{
        "functions",
        \\someethin
        \\else
    },
    .{ "gidle", "nxde" },
});

test "example" {
    const result = thing.get("enter_find_in_files_mode");
    std.debug.print("result: {s}\n", .{result.?});
}
