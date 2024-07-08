const std = @import("std");

pub const InsertCharCtx = struct {
    trigger: []const u8,
    pub fn callback(ctx_: *anyopaque) void {
        const ctx = @as(*@This(), @ptrCast(@alignCast(ctx_)));
        std.debug.print("{s}\n", .{ctx.trigger});
    }
};

pub fn createInsertCharCallbackMap(a: std.mem.Allocator) !std.StringHashMap(InsertCharCtx) {
    var map = std.StringHashMap(InsertCharCtx).init(a);

    try map.put("j", InsertCharCtx{ .trigger = "j" });
    try map.put("k", InsertCharCtx{ .trigger = "k" });

    return map;
}

pub fn createEmptyPrefixMap(a: std.mem.Allocator) std.StringHashMap(bool) {
    const map = std.StringHashMap(bool).init(a);
    return map;
}
