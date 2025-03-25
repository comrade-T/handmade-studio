const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    /////////////////////////////

    const argv = [_][]const u8{"/home/ziontee113/.local/share/nvim/mason/bin/zls"};
    var child = std.process.Child.init(&argv, arena.allocator());

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    /////////////////////////////

    var msg = std.ArrayList(u8).init(arena.allocator());
    defer msg.deinit();

    if (child.stdin) |input_pipe| {
        var buf: [1024]u8 = undefined;

        defer {
            input_pipe.close();
            child.stdin = null;
        }

        {
            const input = "AAAA\r\n";
            try input_pipe.writer().writeAll(input);
        }

        while (true) {
            try msg.appendSlice("----------------------------------------------");

            const std_err_len = try child.stderr.?.read(&buf);
            if (std_err_len > 0) try msg.appendSlice("errr...");
            try msg.appendSlice(buf[0..std_err_len]);

            const std_out_len = try child.stdout.?.read(&buf);
            if (std_out_len > 0) try msg.appendSlice("out...");
            try msg.appendSlice(buf[0..std_out_len]);

            if (std_err_len == 0 and std_out_len == 0) {
                break;
            }
        }
    }

    const term = try child.wait();
    try std.testing.expectEqual(term.Exited, 1);
    try std.testing.expectEqualStrings(
        \\info : ( main ): Starting ZLS 0.13.0 @ '/home/ziontee113/.local/share/nvim/mason/bin/zls'
        \\
        \\error: (default): MissingCarriageReturn
    , msg.items);
}
