const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = a });
    defer pool.deinit();

    try pool.spawn(work, .{ "T500", 5, 500 });
    try pool.spawn(work, .{ "_T100_", 10, 100 });
}

fn work(msg: []const u8, times: usize, sleep_ms: u64) void {
    for (0..times) |i| {
        std.debug.print("{s}: i = {d}\n", .{ msg, i });
        std.time.sleep(sleep_ms * 1_000_000);
    }
}
