const std = @import("std");

pub const InsertCharCtx = struct {
    trigger: []const u8,
    pub fn callback(self: *const @This()) void {
        std.debug.print("AYA: {s}\n", .{self.trigger});
    }
};

pub const InsertCharTriggerMap = std.StringHashMap(InsertCharCtx);
pub const InsertCharPrefixMap = std.StringHashMap(bool);

pub fn createInsertCharCallbackMap(a: std.mem.Allocator) !InsertCharTriggerMap {
    var map = std.StringHashMap(InsertCharCtx).init(a);

    try map.put("j", InsertCharCtx{ .trigger = "j" });
    try map.put("k", InsertCharCtx{ .trigger = "k" });

    return map;
}
