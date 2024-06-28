const std = @import("std");
const main = @import("main.zig");

const port = 8822;

pub const HotReloadChecker = struct {
    lock: std.Thread.RwLock = .{},
    value: bool = false,

    pub fn set_should_reload_on_next_loop(self: *HotReloadChecker, new_value: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.value = new_value;
    }

    pub fn should_reload(self: *HotReloadChecker) bool {
        self.lock.lockShared();
        defer self.lock.unlock();
        return self.value;
    }
};

pub fn spawnServer(checker: *HotReloadChecker) !void {
    const self_addr = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try self_addr.listen(.{ .reuse_address = true });

    while (listener.accept()) |conn| {
        var recv_buf: [4096]u8 = undefined;
        var recv_total: usize = 0;

        while (conn.stream.read(recv_buf[recv_total..])) |recv_len| {
            if (recv_len == 0) break;
            recv_total += recv_len;
            if (std.mem.containsAtLeast(u8, recv_buf[0..recv_total], 1, "\r\n\r\n")) {
                break;
            }
        } else |read_err| {
            return read_err;
        }

        const recv_data = recv_buf[0..recv_total];
        parseHeader(checker, recv_data) catch {};
        try sendResponse(conn);
    } else |err| {
        std.debug.print("error in accept: {}\n", .{err});
    }
}

fn sendResponse(conn: std.net.Server.Connection) !void {
    const httpHead =
        "HTTP/1.1 200 OK \r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    const resp = "<h1>ok</h1>";
    _ = try conn.stream.writer().print(httpHead, .{ "text/html", resp.len });
    _ = try conn.stream.writer().write(resp);
}

fn parseHeader(checker: *HotReloadChecker, header: []const u8) !void {
    var path: []const u8 = "";

    var parts_iter = std.mem.tokenizeSequence(u8, header, "\n\r");
    const metadata = parts_iter.next() orelse "";

    var metadata_iter = std.mem.tokenizeSequence(u8, metadata, "\n");
    while (metadata_iter.next()) |line| {
        var iter = std.mem.tokenizeSequence(u8, line, " ");
        const first = iter.next() orelse "";
        if (!std.mem.eql(u8, first, "POST")) continue;
        path = iter.next() orelse "";
        continue;
    }

    const json_str = parts_iter.next() orelse "";

    if (std.mem.eql(u8, path, "/hot-reload")) checker.set_should_reload_on_next_loop(true);

    std.debug.print("path: {s}\n", .{path});
    std.debug.print("json_str: {s}\n", .{json_str});
}
