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

const LSPClientManager = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const LSPClient = @import("LSPClient.zig");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
clients: LSPClientMap = .{},

const LSPClientMap = std.StringArrayHashMapUnmanaged(*LSPClient);
const LSPKind = enum { zls };

pub fn deinit(self: *@This()) void {
    for (self.clients.values()) |client| client.destroy();
    self.clients.deinit(self.a);
}

pub fn spawnClient(self: *@This(), lsp_kind: LSPKind, root_uri: []const u8) !void {
    const client = try LSPClient.create(self.a);
    try client.start();

    const key = std.fmt.allocPrint(self.a, "{s}{s}", .{ @tagName(lsp_kind), root_uri });
    defer self.a.free(key);

    try client.sendRequestToInitialize();

    try self.clients.put(key, client);
}
