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
id_number: i64 = 0,

pending_content_length: ?usize = null,
b_reader_remnant: []const u8 = "",

const StreamEnum = enum { stdout };
const SERVER_PATH = @embedFile("server_path.txt");

pub fn init(a: Allocator) !LSPClient {
    const path = if (SERVER_PATH[SERVER_PATH.len - 1] == '\r' or SERVER_PATH[SERVER_PATH.len - 1] == '\n')
        SERVER_PATH[0 .. SERVER_PATH.len - 1]
    else
        SERVER_PATH;

    const argv = [_][]const u8{path};

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
    if (self.b_reader_remnant.len > 0) self.a.free(self.b_reader_remnant);
}

pub fn start(self: *@This()) !void {
    try self.proc.spawn();

    self.poller = std.io.poll(self.a, StreamEnum, .{
        .stdout = self.proc.stdout.?,
    });
}

pub fn readOnFrame(self: *@This()) !void {
    const POLL_TIMEOUT_NS = 1_000;
    const poll_result = try self.poller.pollTimeout(POLL_TIMEOUT_NS);

    if (poll_result) {
        const stdout = self.poller.fifo(.stdout);
        var b_reader = std.io.bufferedReaderSize(512, stdout.reader());

        if (self.b_reader_remnant.len > 0) {
            @memcpy(b_reader.buf[0..self.b_reader_remnant.len], self.b_reader_remnant);
            b_reader.start = 0;
            b_reader.end = self.b_reader_remnant.len;

            self.a.free(self.b_reader_remnant);
            self.b_reader_remnant = "";
        }

        while (stdout.count > 0 or b_reader.end - b_reader.start > 0) {
            if (self.pending_content_length == null) {
                const MIN_HEADER_SIZE = 32;
                if (stdout.count < MIN_HEADER_SIZE) {
                    const buf_size = b_reader.end - b_reader.start;
                    if (buf_size < MIN_HEADER_SIZE) {
                        if (buf_size == 0) break;
                        self.b_reader_remnant = try self.a.dupe(u8, b_reader.buf[b_reader.start..b_reader.end]);
                        break;
                    }
                }

                const header = try lsp.BaseProtocolHeader.parse(b_reader.reader());
                self.pending_content_length = header.content_length;
            }

            const content_length = self.pending_content_length orelse continue;
            if (stdout.count < content_length) {
                const buf_size = b_reader.end - b_reader.start;
                if (buf_size < content_length) {
                    if (buf_size == 0) break;
                    self.b_reader_remnant = try self.a.dupe(u8, b_reader.buf[b_reader.start..b_reader.end]);
                    break;
                }
            }

            defer self.pending_content_length = null;

            const json_msg = try self.a.alloc(u8, content_length);
            defer self.a.free(json_msg);
            try b_reader.reader().readNoEof(json_msg);

            std.debug.print("json_msg: '{s}'\n", .{json_msg});
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Getters

fn getIDNumberThenIncrementIt(self: *@This()) i64 {
    defer self.id_number += 1;
    return self.id_number;
}

fn getStdIn(self: *@This()) std.fs.File {
    return self.proc.stdin orelse unreachable;
}

fn getStdout(self: *@This()) std.fs.File {
    return self.proc.stdout orelse unreachable;
}

////////////////////////////////////////////////////////////////////////////////////////////// Request

const ROOT_URI = @embedFile("root_uri.txt");
pub fn sendRequestToInitialize(self: *@This()) !void {
    const uri = if (ROOT_URI[ROOT_URI.len - 1] == '\r' or ROOT_URI[ROOT_URI.len - 1] == '\n')
        ROOT_URI[0 .. ROOT_URI.len - 1]
    else
        ROOT_URI;

    const req = lsp.TypedJsonRPCRequest(types.InitializeParams){
        .id = .{ .number = self.getIDNumberThenIncrementIt() },
        .method = "initialize",
        .params = .{
            .rootUri = uri,
            .capabilities = .{
                .textDocument = .{
                    .definition = .{
                        .dynamicRegistration = false,
                        .linkSupport = false,
                    },
                },
                .general = .{
                    .positionEncodings = &.{.@"utf-8"},
                },
            },
        },
    };
    try serializeObjAndWriteItToFile(self.a, self.getStdIn(), req);
}

pub fn sendInitializedNotification(self: *@This()) !void {
    const req = lsp.TypedJsonRPCNotification(types.InitializedParams){
        .method = "initialized",
        .params = .{},
    };
    try serializeObjAndWriteItToFile(self.a, self.getStdIn(), req);
}

const DOCUMENT_URI = @embedFile("document_uri.txt");
pub fn sendDefinitionRequest(self: *@This()) !void {
    const document_uri = if (DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\r' or DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\n')
        DOCUMENT_URI[0 .. DOCUMENT_URI.len - 1]
    else
        DOCUMENT_URI;

    const req = lsp.TypedJsonRPCRequest(types.DefinitionParams){
        .id = .{ .number = self.getIDNumberThenIncrementIt() },
        .method = "textDocument/definition",
        .params = .{
            .textDocument = .{ .uri = document_uri },
            .position = .{ .line = 41, .character = 16 },
        },
    };
    try serializeObjAndWriteItToFile(self.a, self.getStdIn(), req);
}

pub fn sendDeclarationRequest(self: *@This()) !void {
    const document_uri = if (DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\r' or DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\n')
        DOCUMENT_URI[0 .. DOCUMENT_URI.len - 1]
    else
        DOCUMENT_URI;

    const req = lsp.TypedJsonRPCRequest(types.DeclarationParams){
        .id = .{ .number = self.getIDNumberThenIncrementIt() },
        .method = "textDocument/declaration",
        .params = .{
            .textDocument = .{ .uri = document_uri },
            .position = .{ .line = 41, .character = 16 },
        },
    };
    try serializeObjAndWriteItToFile(self.a, self.getStdIn(), req);
}

const DOCUMENT_TEXT = @embedFile("LSPClient.zig");
pub fn sendDidOpenNotification(self: *@This()) !void {
    const document_uri = if (DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\r' or DOCUMENT_URI[DOCUMENT_URI.len - 1] == '\n')
        DOCUMENT_URI[0 .. DOCUMENT_URI.len - 1]
    else
        DOCUMENT_URI;

    const document_text = if (DOCUMENT_TEXT[DOCUMENT_TEXT.len - 1] == '\r' or DOCUMENT_TEXT[DOCUMENT_TEXT.len - 1] == '\n')
        DOCUMENT_TEXT[0 .. DOCUMENT_TEXT.len - 1]
    else
        DOCUMENT_TEXT;

    const req = lsp.TypedJsonRPCNotification(types.DidOpenTextDocumentParams){
        .method = "textDocument/didOpen",
        .params = .{
            .textDocument = .{
                .uri = document_uri,
                .languageId = "zig",
                .version = 0,
                .text = document_text,
            },
        },
    };
    try serializeObjAndWriteItToFile(self.a, self.getStdIn(), req);
}

fn serializeObjAndWriteItToFile(a: Allocator, file: std.fs.File, obj: anytype) !void {
    const json_str = try std.json.stringifyAlloc(a, obj, .{});
    defer a.free(json_str);
    try writeJsonMessage(file, json_str);
}

fn writeJsonMessage(file: std.fs.File, json_str: []const u8) !void {
    const header: lsp.BaseProtocolHeader = .{ .content_length = json_str.len };

    var buffer: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "{}", .{header}) catch unreachable;

    var iovecs: [2]std.posix.iovec_const = .{
        .{ .base = prefix.ptr, .len = prefix.len },
        .{ .base = json_str.ptr, .len = json_str.len },
    };

    try file.writevAll(&iovecs);
}
