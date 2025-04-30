const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const lsp = @import("lsp_codegen");
const LSPClient = @import("LSPClient");

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var client = try LSPClient.init(arena.allocator());
    try client.start();

    for (0..30) |i| {
        std.debug.print("i = {d}\n", .{i});
        std.Thread.sleep(100 * 1_000_000);

        try client.readOnFrame();

        if (i == 5) try client.sendRequestToInitialize();
        if (i == 6) try client.sendInitializedNotification();
        if (i == 10) try client.sendDidOpenNotification();
        if (i == 14) try client.sendDeclarationRequest();
        if (i == 15) try client.sendDefinitionRequest();
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn tryOutThreadCondition() !void {
    var predicate = false;
    var m = Mutex{};
    var c = Condition{};

    const thread = try std.Thread.spawn(.{}, producer, .{ &predicate, &m, &c });
    consumer(&predicate, &m, &c);
    thread.join();
}

fn consumer(predicate: *bool, m: *Mutex, c: *Condition) void {
    m.lock();
    defer m.unlock();

    while (!predicate.*) {
        std.debug.print("while loop starts\n", .{});
        c.wait(m);
        std.debug.print("wait is done with predicate: {any}\n", .{predicate.*});
    }

    std.Thread.sleep(1_000_000_000);
    std.debug.print("ok man\n", .{});
}

fn producer(predicate: *bool, m: *Mutex, c: *Condition) void {
    {
        m.lock();
        defer m.unlock();

        const sleep_for_sec = 3;
        std.debug.print("start_sleeping for {d} seconds\n", .{sleep_for_sec});
        std.Thread.sleep(sleep_for_sec * 1_000_000_000);

        predicate.* = true;
    }
    c.signal();
}

//////////////////////////////////////////////////////////////////////////////////////////////

const ClientCapabilities = struct {
    // TODO:
};

const InitializeParams = struct {
    processId: ?u32 = null,
    rootUri: []const u8,
    capabilities: ClientCapabilities = .{},
};

fn helloZLSNew() !void {
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

    var transport = lsp.TransportOverStdio.init(child.stdout.?, child.stdin.?);

    const msg = lsp.TypedJsonRPCRequest(InitializeParams){
        .id = .{ .number = 0 },
        .method = "initialize",
        .params = .{
            .rootUri = "",
        },
    };

    const json_str = try std.json.stringifyAlloc(aa, msg, .{});

    //////////////////////////////////////////////////////////////////////////////////////////////

    try transport.writeJsonMessage(json_str);

    while (true) {
        const output = transport.readJsonMessage(aa) catch |err| {
            if (err == error.EndOfStream) break;
            return;
        };
        const parsed = try std.json.parseFromSlice(lsp.JsonRPCMessage, aa, output, .{});

        switch (parsed.value) {
            .request => @panic("not implemented"),
            .notification => |_| std.debug.print("notification: '{s}'\n", .{output}),
            .response => |response| switch (response.result_or_error) {
                .@"error" => std.debug.print("Got error\n", .{}),
                .result => |may_res| {
                    std.debug.print("I got a ?res\n", .{});
                    if (may_res) |res| {
                        switch (res) {
                            .object => |obj| {
                                for (obj.keys()) |key| {
                                    std.debug.print("obj key: '{s}'\n", .{key});
                                }

                                // TODO: use std.json.parseFromValue to parse into a static type
                            },
                            else => std.debug.print("got something else not obj\n", .{}),
                        }
                    }
                    std.debug.print("============================\n", .{});
                },
            },
        }
    }

    //////////////////////////////////////////////////////////////////////////////////////////////

    _ = try child.wait();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn generateDummyJsonRPCMessage(aa: Allocator) ![]const u8 {
    const msg = lsp.JsonRPCMessage{
        .request = .{
            .id = .{ .string = "testing" },
            .method = "workspace/configuration",
            .params = null,
        },
    };

    const json_str = try std.json.stringifyAlloc(aa, msg, .{});
    return try std.fmt.allocPrint(aa, "Content-length: {d}\r\n\r\n{s}\r\n\r\n", .{ json_str.len, json_str });
}

fn helloZLSOld() !void {
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
