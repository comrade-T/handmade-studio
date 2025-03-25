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

    try pool.spawn(cat, .{});
}

fn work(msg: []const u8, times: usize, sleep_ms: u64) void {
    for (0..times) |i| {
        std.debug.print("{s}: i = {d}\n", .{ msg, i });
        std.time.sleep(sleep_ms * 1_000_000);
    }
}

fn cat() void {
    _cat() catch @panic("cat failed!");
}

fn _cat() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    /////////////////////////////

    const argv = [_][]const u8{"cat"};
    var child = std.process.Child.init(&argv, arena.allocator());

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    /////////////////////////////

    if (child.stdin) |input_pipe| {
        defer {
            input_pipe.close();
            child.stdin = null;
        }

        {
            const input = "Saul Goodman";
            try input_pipe.writer().writeAll(input);
            var buf: [1024]u8 = undefined;
            const len = try child.stdout.?.read(&buf);
            try std.testing.expectEqualStrings(input, buf[0..len]);
        }

        {
            const input = "Walter White";
            try input_pipe.writer().writeAll(input);
            var buf: [1024]u8 = undefined;
            const len = try child.stdout.?.read(&buf);
            try std.testing.expectEqualStrings(input, buf[0..len]);
        }
    }

    const term = try child.wait();
    try std.testing.expectEqual(term.Exited, 0);

    std.debug.print("cat finished\n", .{});
}
