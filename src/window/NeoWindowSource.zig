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

const MockIterator = BufferOrchestrator.MockIterator;
const ByteRange = BufferOrchestrator.ByteRange;

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
            assert(try lang_hub.parseMainTreeFirstTime(buf, .{ .lang_choice = lang_choice }));
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

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn insertChars(self: *@This(), orchestrator: *BufferOrchestrator, may_lang_hub: ?*LangHub, cursor_byte_range_iter: anytype, chars: []const u8) !void {
    assert(orchestrator.pending != null);
    assert(self.buf == orchestrator.pending.?.buf);
    try orchestrator.insertChars(chars, cursor_byte_range_iter);

    const lang_hub = may_lang_hub orelse return;
    cursor_byte_range_iter.reset();

    // TODO: it's better to create another abstraction to deal with this
    // it'll be able to store then process all the edit information required

    var i: usize = 0;
    while (cursor_byte_range_iter.next()) |old_byte_range| {
        defer i += 1;
        try lang_hub.editMainTree(self.buf, .{
            .start_byte = old_byte_range.start,
            .old_end_byte = old_byte_range.end,
            .new_end_byte = orchestrator.pending.?.trackers[i].cursor,
        });
    }

    try lang_hub.reparseMainTree(orchestrator, self.buf);
}

test insertChars {
    const a = std.testing.allocator;
    var lang_hub = LangHub{ .a = a };
    defer lang_hub.deinit();

    var orchestrator = BufferOrchestrator{ .a = a };
    defer orchestrator.deinit();

    {
        var ws = try NeoWindowSource.initFromFile(a, &orchestrator, &lang_hub, "src/window/fixtures/dummy_3_lines.zig");
        defer ws.deinit(a, &orchestrator);
        try eqStr("const a = 10;\nvar not_false = true;\nconst Allocator = std.mem.Allocator;\n", try ws.buf.toString(idc_if_it_leaks, .lf));

        try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
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

        {
            var initial_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
            try orchestrator.startEditing(ws.buf, &initial_byte_range_iter);

            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 0, .end = 0 }} };
                try ws.insertChars(&orchestrator, &lang_hub, &edit_byte_range_iter, "/");
                try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
                    .{ "/", &.{"operator"} },
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
            {
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 1, .end = 1 }} };
                try ws.insertChars(&orchestrator, &lang_hub, &edit_byte_range_iter, "/");
                try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
                    .{ "//const a = 10;", &.{ "comment", "spell" } },
                    null,
                });
            }
            {
                std.debug.print("===========================\n", .{});
                var edit_byte_range_iter = MockIterator(ByteRange){ .items = &.{.{ .start = 2, .end = 2 }} };
                try ws.insertChars(&orchestrator, &lang_hub, &edit_byte_range_iter, " ");
                try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
                    .{ "// const a = 10;", &.{ "comment", "spell" } },
                    null,
                });
                std.debug.print("===========================\n", .{});
            }

            try orchestrator.stopEditing();
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// LineIterator

pub const LineIterator = struct {
    chariter: CharacterForwardIterator,
    capiter: LangHub.CaptureIterator = .{},

    fn init(root: Buffer.rcr.RcNode, linenr: u32) !LineIterator {
        const byte_offset = try Buffer.rcr.getByteOffsetOfPosition(root, linenr, 0);
        return LineIterator{ .chariter = try CharacterForwardIterator.init(root.value, byte_offset) };
    }

    fn next(self: *@This(), captures: LangHub.Captures) ?Result {
        const chariter_result = self.chariter.next() orelse return null;
        const capiter_result = self.capiter.next(captures);

        if (chariter_result.code == '\n') return null;

        return Result{
            .code_point = chariter_result.code,
            .code_point_len = chariter_result.len,
            .captures = capiter_result,
        };
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
        var ws = try NeoWindowSource.initFromFile(a, &orchestrator, &lang_hub, "src/window/fixtures/dummy.md");
        defer ws.deinit(a, &orchestrator);
        try eqStr("# Hello World\n\ncool `cooler`\n", try ws.buf.toString(idc_if_it_leaks, .lf));

        try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
            .{ "#", &.{"punctuation.special"} },
            .{ " ", &.{} },
            .{ "Hello World", &.{"text.title"} },
            null,
        });
    }

    {
        var ws = try NeoWindowSource.initFromFile(a, &orchestrator, &lang_hub, "src/window/fixtures/dummy_3_lines.zig");
        defer ws.deinit(a, &orchestrator);
        try eqStr("const a = 10;\nvar not_false = true;\nconst Allocator = std.mem.Allocator;\n", try ws.buf.toString(idc_if_it_leaks, .lf));

        try testLineIter(ws.buf, &orchestrator, &lang_hub, 0, &.{
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
        try testLineIter(ws.buf, &orchestrator, &lang_hub, 1, &.{
            .{ "var", &.{"keyword"} },
            .{ " ", &.{} },
            .{ "not_false", &.{"variable"} },
            .{ " ", &.{} },
            .{ "=", &.{"operator"} },
            .{ " ", &.{} },
            .{ "true", &.{"boolean"} },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
        try testLineIter(ws.buf, &orchestrator, &lang_hub, 2, &.{
            .{ "const", &.{"keyword"} },
            .{ " ", &.{} },
            .{ "Allocator", &.{ "type", "variable" } },
            .{ " ", &.{} },
            .{ "=", &.{"operator"} },
            .{ " ", &.{} },
            .{ "std", &.{"variable"} },
            .{ ".", &.{"punctuation.delimiter"} },
            .{ "mem", &.{ "variable.member", "variable" } },
            .{ ".", &.{"punctuation.delimiter"} },
            .{ "Allocator", &.{ "variable.member", "type", "variable" } },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
    }
}

const Expected = struct { []const u8, []const []const u8 };

fn testLineIter(buf: *Buffer, orchestrator: *BufferOrchestrator, lang_hub: *LangHub, linenr: u32, expecteds: []const ?Expected) !void {
    const buf_tree_list = lang_hub.trees.get(buf) orelse unreachable;
    const main_tree = buf_tree_list.items[0];

    const capture_map = lang_hub.captures.get(main_tree) orelse unreachable;
    const captured_lines = capture_map.get(lang_hub.getHightlightQueryIndexes(buf).ptr) orelse unreachable;
    const captures: LangHub.Captures = captured_lines.items[linenr];

    // switch (captures) {
    //     .std => |caps| std.debug.print("{any}\n", .{caps}),
    //     .long => |caps| std.debug.print("{any}\n", .{caps}),
    // }

    var line_iter = try LineIterator.init(orchestrator.getRoot(buf), linenr);
    for (expecteds, 0..) |may_expected, clump_index| {
        if (may_expected == null) {
            try eq(null, line_iter.next(captures));
            return;
        }
        const expected = may_expected.?;

        errdefer std.debug.print("failed at line '{d}' | clump_index = '{d}'\n", .{ linenr, clump_index });

        var x: usize = 0;
        var cp_iter = Buffer.rcr.code_point.Iterator{ .bytes = expected[0] };
        while (cp_iter.next()) |code_point| {
            defer x += 1;
            const line_iter_res = line_iter.next(captures);

            errdefer {
                std.debug.print("failed at char #{d}\n", .{x});
                for (line_iter_res.?.captures, 0..) |capture, i| {
                    const langsuite = lang_hub.getLangSuite(.{ .language = main_tree.getLanguage() }) catch unreachable;
                    const sq = langsuite.queries.items[capture.query_id];
                    const capture_name = sq.query.getCaptureNameForId(capture.capture_id);
                    std.debug.print("i = {d} | capture_name: '{s}'\n", .{ i, capture_name });
                }
            }

            try eq(code_point.code, line_iter_res.?.code_point);
            // std.debug.print("#{d} | char: '{s}' | expected[1].len: {d} | captures.len {d}\n", .{
            //     x,
            //     expected[0][code_point.offset .. code_point.offset + code_point.len],
            //     expected[1].len,
            //     line_iter_res.?.captures.len,
            // });
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
