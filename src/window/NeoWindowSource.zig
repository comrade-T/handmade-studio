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

////////////////////////////////////////////////////////////////////////////////////////////////

const NeoWindowSource = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangHub = @import("NeoLangHub");
const BufferOrchestrator = @import("BufferOrchestrator");
const Buffer = BufferOrchestrator.Buffer;
const CharacterForwardIterator = Buffer.rcr.CharacterForwardIterator;

//////////////////////////////////////////////////////////////////////////////////////////////

buf: *Buffer,
origin: Origin,

pub const Origin = union(enum) {
    string: i64,
    file: []const u8,
};

pub fn initFromString(orchestrator: *BufferOrchestrator, str_id: i64, str_content: []const u8) !NeoWindowSource {
    return NeoWindowSource{
        .buf = try orchestrator.createBufferFromString(str_content),
        .origin = .{ .string = str_id },
    };
}

pub fn initFromFile(a: Allocator, orchestrator: *BufferOrchestrator, may_lang_hub: ?*LangHub, path: []const u8) !NeoWindowSource {
    const buf = try orchestrator.createBufferFromFile(path);
    if (may_lang_hub) |lang_hub| {
        if (LangHub.getLangChoiceFromFilePath(path)) |lang_choice| {
            assert(try lang_hub.parseMainTree(buf, .{ .lang_choice = lang_choice }));
            try lang_hub.initializeCapturesForMainTree(buf, lang_hub.getHightlightQueryIndexes(buf));
        }
    }
    return NeoWindowSource{
        .buf = buf,
        .origin = .{ .file = try a.dupe(u8, path) },
    };
}

pub fn deinit(self: *@This(), a: Allocator, orchestrator: *BufferOrchestrator) void {
    orchestrator.removeBuffer(self.buf);
    switch (self.origin) {
        .string => {},
        .file => |path| a.free(path),
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const LineIterator = struct {
    chariter: CharacterForwardIterator,
    capiter: LangHub.CaptureIterator = .{},

    fn init(buf: *const Buffer, linenr: u32) !void {
        const byte_offset = try buf.getByteOffsetOfPosition(linenr, 0);
        return LineIterator{ .chariter = CharacterForwardIterator.init(buf.getCurrentRoot().value, byte_offset) };
    }

    fn next(self: *@This(), captures: LangHub.Captures) ?Result {
        const may_chariter_result = self.chariter.next();
        const may_capiter_result = self.capiter.next(captures);

        if (may_chariter_result) |chariter_result| {
            assert(may_capiter_result != null);
            if (may_capiter_result) |capiter_result| {
                return Result{
                    .code_point = chariter_result.code,
                    .code_point_len = chariter_result.len,
                    .captures = capiter_result,
                };
            }
        }

        return null;
    }

    const Result = struct {
        code_point: u21,
        code_point_len: u3,
        captures: []const LangHub.CaptureIterator.Capture,
    };
};

test initFromFile {
    const a = std.testing.allocator;
    var lang_hub = LangHub{ .a = a };
    defer lang_hub.deinit();

    var orchestrator = BufferOrchestrator{ .a = a };
    defer orchestrator.deinit();

    {
        var ws = try NeoWindowSource.initFromFile(a, &orchestrator, &lang_hub, "src/window/fixtures/dummy.zig");
        defer ws.deinit(a, &orchestrator);

        // TODO: what else do I want to test?
        // - capturing stuffs -> from NeoWindowSource.initFromFile() ==> I should map this out properly on canvas
        // - iterate through those captures
    }
}
