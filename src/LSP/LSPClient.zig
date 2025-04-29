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

a: Allocator,
proc: std.process.Child,
poller: std.io.Poller(StreamEnum) = undefined,
request: ?Request = null,

const StreamEnum = enum { stdout };
const SERVER_PATH = @embedFile("server_path.txt");

const Request = struct {
    // TODO:
};

pub fn init(a: Allocator) !LSPClient {
    const argv = [_][]const u8{SERVER_PATH};

    var self = LSPClient{
        .a = a,
        .proc = std.process.Child.init(&argv, a),
    };

    self.proc.stdin_behavior = .Pipe;
    self.proc.stdout_behavior = .Pipe;
    self.proc.stderr_behavior = .Pipe;

    return self;
}

pub fn deinit(self: *@This()) !void {
    self.poller.deinit();
}

pub fn start(self: *@This()) !void {
    try self.proc.spawn();

    self.poller = std.io.poll(self.a, enum { stdout }, .{
        .stdout = self.proc.stdout.?,
    });
}

pub fn onFrame(self: *@This()) !void {

    ///////////////////////////// Read

    const POLL_TIMEOUT_NS = 1_000;
    const poll_result = try self.poller.pollTimeout(POLL_TIMEOUT_NS);

    if (poll_result) {
        // TODO: read from stdout
    }

    ///////////////////////////// Write

    if (self.request) |request| {
        const json_str = try std.json.stringifyAlloc(self.a, request, .{});
        defer self.a.free(json_str);

        // TODO: write json_str to stdin
    }
}
