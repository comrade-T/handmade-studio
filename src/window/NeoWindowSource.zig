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
const idc_if_it_leaks = std.heap.page_allocator;

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

    fn init(buf: *const Buffer, linenr: u32) !LineIterator {
        const byte_offset = try buf.getByteOffsetOfPosition(linenr, 0);
        return LineIterator{ .chariter = try CharacterForwardIterator.init(buf.getCurrentRoot().value, byte_offset) };
    }

    fn next(self: *@This(), captures: LangHub.Captures) ?Result {
        const may_chariter_result = self.chariter.next();
        const capiter_result = self.capiter.next(captures);

        if (may_chariter_result) |chariter_result| {
            return Result{
                .code_point = chariter_result.code,
                .code_point_len = chariter_result.len,
                .captures = capiter_result,
            };
        }

        return null;
    }

    const Result = struct {
        code_point: u21,
        code_point_len: u3,
        captures: []const LangHub.CaptureIterator.Capture,
    };
};

test LineIterator {
    const a = std.testing.allocator;
    var lang_hub = LangHub{ .a = a };
    defer lang_hub.deinit();

    var orchestrator = BufferOrchestrator{ .a = a };
    defer orchestrator.deinit();

    {
        var ws = try NeoWindowSource.initFromFile(a, &orchestrator, &lang_hub, "src/window/fixtures/dummy_3_lines.zig");
        defer ws.deinit(a, &orchestrator);
        try eqStr("const a = 10;\nvar not_false = true;\nconst Allocator = std.mem.Allocator;\n", try ws.buf.toString(idc_if_it_leaks, .lf));

        try testLineIter(ws.buf, &lang_hub, 0, &.{
            .{ "const", &.{"keyword"} },
            .{ " ", &.{} },
            .{ "a", &.{"variable"} },
            .{ " ", &.{} },
            .{ "=", &.{"operator"} },
            .{ " ", &.{} },
            .{ "10", &.{"number"} },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
    }
}

const Expected = struct { []const u8, []const []const u8 };

fn testLineIter(buf: *Buffer, lang_hub: *LangHub, linenr: u32, exp: []const ?Expected) !void {
    const buf_tree_list = lang_hub.trees.get(buf) orelse unreachable;
    const main_tree = buf_tree_list.items[0];

    const capture_map = lang_hub.captures.get(main_tree) orelse unreachable;
    const captured_lines = capture_map.get(lang_hub.getHightlightQueryIndexes(buf).ptr) orelse unreachable;
    const captures = captured_lines.items[linenr];

    var line_iter = try LineIterator.init(buf, linenr);
    for (exp, 0..) |may_e, clump_index| {
        if (may_e == null) {
            try eq(null, line_iter.next(captures));
            return;
        }
        const expected = may_e.?;

        errdefer std.debug.print("failed at line '{d}' | clump_index = '{d}'\n", .{ linenr, clump_index });

        var cp_iter = Buffer.rcr.code_point.Iterator{ .bytes = expected[0] };
        while (cp_iter.next()) |code_point| {
            const line_iter_res = line_iter.next(captures);

            errdefer {
                for (line_iter_res.?.captures, 0..) |capture, i| {
                    const langsuite = lang_hub.getLangSuite(.{ .language = main_tree.getLanguage() }) catch unreachable;
                    const sq = langsuite.queries.items[capture.query_id];
                    const capture_name = sq.query.getCaptureNameForId(capture.capture_id);
                    std.debug.print("i = {d} | capture_name: '{s}'\n", .{ i, capture_name });
                }
            }

            try eq(code_point.code, line_iter_res.?.code_point);
            try eq(expected[1].len, line_iter_res.?.captures.len);

            for (line_iter_res.?.captures, 0..) |capture, i| {
                const langsuite = try lang_hub.getLangSuite(.{ .language = main_tree.getLanguage() });
                const sq = langsuite.queries.items[capture.query_id];
                const capture_name = sq.query.getCaptureNameForId(capture.capture_id);
                try eqStr(expected[1][i], capture_name);
            }
        }
    }
}
