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
    const thread = try std.Thread.spawn(.{ .allocator = self.aa }, spawnAndWaitPoll, .{self});
    thread.detach();
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn sendBlah(self: *@This()) void {
    {
        self.lock.lock();
        defer self.lock.unlock();

        self.msg_kind = .blah;
    }
    self.condition.signal();
}

pub fn sendMeh(self: *@This()) void {
    {
        self.lock.lock();
        defer self.lock.unlock();

        self.msg_kind = .meh;
    }
    self.condition.signal();
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn spawnAndWaitPoll(self: *@This()) !void {
    self.proc.spawn() catch unreachable;
    self.transport = lsp.TransportOverStdio.init(self.proc.stdout.?, self.proc.stdin.?);

    var poller = std.io.poll(self.aa, enum { stdout }, .{
        .stdout = self.proc.stdout.?,
    });
    defer poller.deinit();

    while (true) {
        const poll_result = try poller.poll();

        std.debug.print("=========================================================\n", .{});
        std.debug.print("poll result: {any}\n", .{poll_result});
        std.debug.print("count: {d}\n", .{poller.fifo(.stdout).count});

        if (poll_result) {
            const reader = poller.fifo(.stdout).reader();

            while (poller.fifo(.stdout).count > 0) {
                std.debug.print("---------------------\n", .{});

                const header = try lsp.BaseProtocolHeader.parse(reader);
                std.debug.print("header.content_length {d}\n", .{header.content_length});
                std.debug.print("count after header: {d}\n", .{poller.fifo(.stdout).count});

                const json_message = try self.aa.alloc(u8, header.content_length);
                try reader.readNoEof(json_message);

                std.debug.print("json_message: {s}\n", .{json_message});
                std.debug.print("count after json_message: {d}\n", .{poller.fifo(.stdout).count});
            }
        }
    }
}
