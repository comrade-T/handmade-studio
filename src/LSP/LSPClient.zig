// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const LSPClient = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Thread = std.Thread;
const assert = std.debug.assert;

const lsp = @import("lsp_codegen");
const types = lsp.types;

//////////////////////////////////////////////////////////////////////////////////////////////

aa: Allocator,
proc: std.process.Child,

transport: lsp.TransportOverStdio = undefined,
lock: Mutex = .{},
condition: Condition = .{},

msg_kind: enum { initialize, blah, meh } = .initialize,

pub fn init(aa: Allocator) !LSPClient {
    const argv = [_][]const u8{"/home/ziontee113/.local/share/nvim/mason/bin/zls"};

    var self = LSPClient{
        .aa = aa,
        .proc = std.process.Child.init(&argv, aa),
    };

    self.proc.stdin_behavior = .Pipe;
    self.proc.stdout_behavior = .Pipe;
    self.proc.stderr_behavior = .Pipe;

    return self;
}

pub fn start(self: *@This()) !void {
    const thread = try Thread.spawn(.{ .allocator = self.aa }, spawnAndWait, .{self});
    thread.detach();
}

fn spawnAndWait(self: *@This()) void {
    self.proc.spawn() catch unreachable;
    self.transport = lsp.TransportOverStdio.init(self.proc.stdout.?, self.proc.stdin.?);

    const read_thread = Thread.spawn(.{ .allocator = self.aa }, handleReads, .{self}) catch unreachable;
    read_thread.detach();

    self.handleWrites();

    _ = self.proc.wait() catch unreachable;

    std.debug.print("yo waiting is done!\n", .{});
}

fn handleReads(self: *@This()) void {
    defer std.debug.print("yo no more reads\n", .{});

    while (true) {
        const output = self.transport.readJsonMessage(self.aa) catch |err| {
            if (err == error.EndOfStream) break;
            return;
        };
        const parsed = std.json.parseFromSlice(lsp.JsonRPCMessage, self.aa, output, .{}) catch unreachable;

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
}

fn handleWrites(self: *@This()) void {
    const ClientCapabilities = struct {
        // TODO:
    };

    const InitializeParams = struct {
        processId: ?u32 = null,
        rootUri: []const u8,
        capabilities: ClientCapabilities = .{},
    };

    const initialize_request = lsp.TypedJsonRPCRequest(InitializeParams){
        .id = .{ .number = 0 },
        .method = "initialize",
        .params = .{
            .rootUri = "",
        },
    };

    const blah_request = lsp.TypedJsonRPCRequest(InitializeParams){
        .id = .{ .string = "blah" },
        .method = "blah",
        .params = null,
    };

    const meh_request = lsp.TypedJsonRPCRequest(InitializeParams){
        .id = .{ .string = "meh" },
        .method = "meh",
        .params = null,
    };

    /////////////////////////////

    self.lock.lock();
    defer self.lock.unlock();

    while (true) {
        const request = switch (self.msg_kind) {
            .initialize => initialize_request,
            .blah => blah_request,
            .meh => meh_request,
        };
        const json_str = std.json.stringifyAlloc(self.aa, request, .{}) catch unreachable;
        self.transport.writeJsonMessage(json_str) catch unreachable;

        if (self.msg_kind == .meh) {
            self.proc.stdin.?.close();
            self.proc.stdin = null;
            break;
        }

        self.condition.wait(&self.lock);
    }

    std.debug.print("yo no more write\n", .{});
}
