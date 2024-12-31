const std = @import("std");

pub fn main() !void {
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
}
