const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const lsp = @import("lsp");

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    try helloZLS();
}

fn generateDummyJsonRPCMessage(aa: Allocator) ![]const u8 {
    const msg = lsp.JsonRPCMessage{
        .request = .{
            .id = .{ .string = "ligma" },
            .method = "test",
            .params = null,
        },
    };

    const json_str = try std.json.stringifyAlloc(aa, msg, .{});
    return try std.fmt.allocPrint(aa, "Content-length: {d}\r\n\r\n{s}\r\n\r\n", .{ json_str.len, json_str });
}

fn helloZLS() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const argv = [_][]const u8{"/home/ziontee113/.local/share/nvim/mason/bin/zls"};
    var child = std.process.Child.init(&argv, aa);

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    /////////////////////////////

    var debug_msg = std.ArrayList(u8).init(aa);

    {
        defer {
            child.stdin.?.close();
            child.stdin = null;
        }

        const msg = try generateDummyJsonRPCMessage(aa);
        try child.stdin.?.writeAll(msg);
        try debug_msg.appendSlice("\n-----------------------------------------------------\n");
        {
            const output = try child.stdout.?.readToEndAlloc(aa, 1024);
            try debug_msg.appendSlice(output);

            try debug_msg.appendSlice("\n===================================\n");

            const err = try child.stderr.?.readToEndAlloc(aa, 1024);
            try debug_msg.appendSlice(err);
        }
    }

    /////////////////////////////

    _ = try child.wait();
    std.debug.print("{s}\n", .{debug_msg.items});
}
