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

const WindowSource = @This();
const std = @import("std");
const ztracy = @import("ztracy");
const code_point = @import("code_point");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const Buffer = @import("Buffer");
pub const InitFrom = Buffer.InitFrom;
const CursorRange = Buffer.CursorRange;
const LangSuite = @import("LangSuite");
const CursorManager = @import("CursorManager");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

from: InitFrom,
path: []const u8 = "",

buf: *Buffer,
ls: ?*LangSuite = null,
cap_list: CapList,

const CapList = ArrayList([]StoredCapture);

pub fn create(a: Allocator, from: InitFrom, source: []const u8, may_lang_hub: ?*LangSuite.LangHub) !*WindowSource {
    var self = try a.create(@This());
    self.* = WindowSource{
        .a = a,
        .from = from,
        .buf = try Buffer.create(a, from, source),
        .cap_list = CapList.init(a),
    };
    switch (from) {
        .string => {},
        .file => {
            assert(may_lang_hub != null);
            if (may_lang_hub) |lang_hub| {
                self.path = try self.a.dupe(u8, source);
                try self.initiateTreeSitterForFile(lang_hub);
                try self.populateCapListWithAllCaptures();
            }
        },
    }
    return self;
}

test create {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();
    { // no Tree Sitter
        var ws = try WindowSource.create(testing_allocator, .string, "hello world", &lang_hub);
        defer ws.destroy();
        try eq(null, ws.buf.tstree);
        try eq(0, ws.cap_list.items.len);
        try eqStr("hello world", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));
    }
    { // with Tree Sitter
        var ws = try WindowSource.create(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
        defer ws.destroy();
        try eqStr("const a = 10;\nvar not_false = true;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));
        try eq(3, ws.cap_list.items.len);
    }
}

pub fn destroy(self: *@This()) void {
    self.buf.destroy();
    for (self.cap_list.items) |slice| self.a.free(slice);
    self.cap_list.deinit();
    if (self.from == .file) self.a.free(self.path);
    self.a.destroy(self);
}

pub fn getURI(self: *@This(), a: Allocator) !?[]u8 {
    if (self.path.len == 0) null;
    const abs_path = try std.fs.cwd().realpathAlloc(a, self.path);
    defer a.free(abs_path);
    return try std.fmt.allocPrint(a, "file://{s}", .{abs_path});
}

fn initiateTreeSitterForFile(self: *@This(), lang_hub: *LangSuite.LangHub) !void {
    const lang_choice = LangSuite.getLangChoiceFromFilePath(self.path) orelse return;
    self.ls = try lang_hub.get(lang_choice);
    try self.buf.initiateTreeSitter(self.ls.?);
}

////////////////////////////////////////////////////////////////////////////////////////////// getCaptures

const CapturedLinesMap = std.AutoArrayHashMap(usize, StoredCaptureList);
const StoredCaptureList = std.ArrayListUnmanaged(StoredCapture);
const max_int_u32 = std.math.maxInt(u32);

fn getCaptures(self: *@This(), start: usize, end: usize) !CapturedLinesMap {
    assert(self.ls != null and self.buf.tstree != null);

    var map = CapturedLinesMap.init(self.a);
    const ls = self.ls orelse return map;
    const tree = self.buf.tstree orelse return map;

    for (start..end + 1) |i| try map.put(i, try StoredCaptureList.initCapacity(self.a, 8));

    for (ls.highlight_queries.values(), 0..) |sq, query_index| {
        var cursor = try LangSuite.ts.Query.Cursor.create();
        cursor.execute(sq.query, tree.getRootNode());
        cursor.setPointRange(
            .{ .row = @intCast(start), .column = 0 },
            .{ .row = @intCast(end + 1), .column = 0 },
        );

        const targets_buf_capacity = 8;
        var targets_buf: [@sizeOf(LangSuite.QueryFilter.CapturedTarget) * targets_buf_capacity]u8 = undefined;
        while (sq.filter.nextMatch(&self.buf.ropeman, &targets_buf, targets_buf_capacity, cursor)) |match| {
            if (!match.all_predicates_matched) continue;
            for (match.targets) |target| {
                for (target.start_line..target.end_line + 1) |linenr| {
                    const cap = StoredCapture{
                        .query_index = @intCast(query_index),
                        .capture_id = target.capture_id,
                        .start_col = if (linenr == target.start_line) target.start_col else 0,
                        .end_col = if (linenr == target.end_line) target.end_col else max_int_u32,
                    };
                    var list = map.getPtr(linenr) orelse continue;
                    try list.append(self.a, cap);
                }
            }
        }
    }

    for (map.values()) |list| std.mem.sort(StoredCapture, list.items, {}, StoredCapture.lessThan);
    return map;
}

const dummy_2_lines_first_line_matches: []const StoredCapture = &.{
    .{ .start_col = 0, .end_col = 5, .query_index = 0, .capture_id = 28 }, // @type.qualifier
    .{ .start_col = 6, .end_col = 7, .query_index = 0, .capture_id = 2 }, // @variable
    .{ .start_col = 10, .end_col = 12, .query_index = 0, .capture_id = 12 }, // number
    .{ .start_col = 12, .end_col = 13, .query_index = 0, .capture_id = 33 }, // punctuation.delimiter
};
const dummy_2_lines_second_line_matches: []const StoredCapture = &.{
    .{ .start_col = 0, .end_col = 3, .query_index = 0, .capture_id = 28 }, // @type.qualifier
    .{ .start_col = 4, .end_col = 13, .query_index = 0, .capture_id = 2 }, // @variable
    .{ .start_col = 16, .end_col = 20, .query_index = 0, .capture_id = 14 }, // boolean
    .{ .start_col = 20, .end_col = 21, .query_index = 0, .capture_id = 33 }, // punctuation.delimiter
};

const dummy_2_lines_commented_first_line_matches: []const StoredCapture = &.{
    .{ .start_col = 0, .end_col = 16, .query_index = 0, .capture_id = 0 },
    .{ .start_col = 0, .end_col = 16, .query_index = 0, .capture_id = 1 },
};
const dummy_2_lines_commented_second_line_matches: []const StoredCapture = &.{
    .{ .start_col = 0, .end_col = 24, .query_index = 0, .capture_id = 0 },
    .{ .start_col = 0, .end_col = 24, .query_index = 0, .capture_id = 1 },
};

test getCaptures {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    {
        var ws = try WindowSource.create(testing_allocator, .file, "src/window/fixtures/dummy_2_lines.zig", &lang_hub);
        defer ws.destroy();

        const source = try ws.buf.ropeman.toString(testing_allocator, .lf);
        defer testing_allocator.free(source);
        try eqStr(
            \\const a = 10;
            \\var not_false = true;
            \\
        , source);

        try eqStr("type.qualifier", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(28));
        try eqStr("variable", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(2));
        try eqStr("number", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(12));
        try eqStr("boolean", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(14));
        try eqStr("punctuation.delimiter", ws.ls.?.queries.get(LangSuite.DEFAULT_QUERY_ID).?.query.getCaptureNameForId(33));

        { // entire file
            var map = try ws.getCaptures(0, ws.buf.ropeman.root.value.weights().bols - 1);
            defer {
                for (map.values()) |*list| list.deinit(testing_allocator);
                map.deinit();
            }

            try eq(3, map.keys().len);
            try eqSlice(StoredCapture, dummy_2_lines_first_line_matches, map.get(0).?.items);
            try eqSlice(StoredCapture, dummy_2_lines_second_line_matches, map.get(1).?.items);
            try eqSlice(StoredCapture, &.{}, map.get(2).?.items);
        }

        { // only 1st line
            var map = try ws.getCaptures(0, 0);
            defer {
                for (map.values()) |*list| list.deinit(testing_allocator);
                map.deinit();
            }

            try eq(1, map.keys().len);
            try eqSlice(StoredCapture, dummy_2_lines_first_line_matches, map.get(0).?.items);
        }
    }
}

fn populateCapListWithAllCaptures(self: *@This()) !void {
    if (self.buf.tstree == null) return;

    var map = try self.getCaptures(0, self.buf.ropeman.getNumOfLines() - 1);
    defer map.deinit();
    assert(map.values().len == self.buf.ropeman.getNumOfLines());

    assert(self.cap_list.items.len == 0);
    for (map.values()) |*list| try self.cap_list.append(try list.toOwnedSlice(self.a));
}

////////////////////////////////////////////////////////////////////////////////////////////// insertChars()

pub const ReplaceInfo = struct {
    replace_start: usize,
    replace_len: usize,
    start_line: usize,
    end_line: usize,
};

pub fn insertChars(self: *@This(), a: Allocator, chars: []const u8, cm: *CursorManager) !?[]const ReplaceInfo {
    assert(cm.cursors.values().len > 0);
    assert(cm.cursor_mode == .point);
    if (cm.cursor_mode != .point) return null;

    const inputs = try cm.produceCursorPoints(self.a);
    defer self.a.free(inputs);

    const outputs, const ts_ranges = try self.buf.insertChars(self.a, chars, inputs);
    defer self.a.free(outputs);

    // update cursors
    assert(inputs.len == outputs.len);
    for (outputs, 0..) |p, i| cm.cursors.values()[i].setActiveAnchor(cm, p.line, p.col);

    ///////////////////////////// Update CapList

    var linenr_map = EditLinenrMap.init(self.a);
    try linenr_map.ensureTotalCapacity(512);
    defer linenr_map.deinit();

    var replace_info_list = try ReplaceInfoList.initCapacity(a, inputs.len);
    const INSERT_REPLACE_RANGE = 1; // because this is insert, with .point cursor_mode

    for (0..inputs.len) |i| {
        assert(outputs[i].line >= inputs[i].line);
        const info = ReplaceInfo{
            .replace_start = inputs[i].line,
            .replace_len = INSERT_REPLACE_RANGE,
            .start_line = inputs[i].line,
            .end_line = outputs[i].line,
        };
        if (self.buf.tstree != null) try self.updateCapList(info);
        try replace_info_list.append(info);
        for (inputs[i].line..outputs[i].line + 1) |linenr| try linenr_map.put(@intCast(linenr), {});
    }

    try self.updateWithTreeSitterRanges(ts_ranges, &linenr_map, &replace_info_list);
    return try replace_info_list.toOwnedSlice();
}

fn updateCapList(self: *@This(), ri: ReplaceInfo) !void {
    var new_captures = try self.getCaptures(ri.start_line, ri.end_line);
    defer new_captures.deinit();

    const new_values = try self.a.alloc([]StoredCapture, ri.end_line + 1 - ri.start_line);
    defer self.a.free(new_values);
    for (new_captures.values(), 0..) |*list, i| new_values[i] = try list.toOwnedSlice(self.a);

    for (ri.replace_start..ri.replace_start + ri.replace_len) |i| self.a.free(self.cap_list.items[i]);
    try self.cap_list.replaceRange(ri.replace_start, ri.replace_len, new_values);
}

////////////////////////////////////////////////////////////////////////////////////////////// deleteRanges()

const EditLinenrMap = std.AutoArrayHashMap(u32, void);
const ReplaceInfoList = std.ArrayList(ReplaceInfo);

pub const DeleteRangesKind = enum {
    backspace,
    range,

    in_single_quote,
    in_word,
    in_WORD,
};

pub fn deleteRanges(self: *@This(), a: Allocator, cm: *CursorManager, kind: DeleteRangesKind) !?[]const ReplaceInfo {
    const zone = ztracy.ZoneNC(@src(), "WindowSource.deleteRanges()", 0x00AAFF);
    defer zone.End();

    assert(cm.cursors.values().len > 0);

    var inputs: []CursorRange = undefined;
    switch (kind) {
        .backspace => {
            inputs = try cm.produceBackspaceRanges(self.a, &self.buf.ropeman);
            assert(cm.cursor_mode == .point);
            if (cm.cursor_mode != .point) return null;
        },
        .range => {
            inputs = try cm.produceCursorRanges(self.a);
            assert(cm.cursor_mode == .range);
            if (cm.cursor_mode != .range) return null;
        },

        /////////////////////////////

        .in_single_quote => {
            inputs = try cm.produceInSingleQuoteRanges(self.a, &self.buf.ropeman);
            assert(cm.cursor_mode == .point);
            if (cm.cursor_mode != .point) return null;
        },

        .in_word => {
            inputs = try cm.produceInWordRanges(self.a, &self.buf.ropeman, .word);
            assert(cm.cursor_mode == .point);
            if (cm.cursor_mode != .point) return null;
        },
        .in_WORD => {
            inputs = try cm.produceInWordRanges(self.a, &self.buf.ropeman, .WORD);
            assert(cm.cursor_mode == .point);
            if (cm.cursor_mode != .point) return null;
        },
    }
    defer self.a.free(inputs);

    const outputs, const ts_ranges = try self.buf.deleteRanges(self.a, inputs);
    defer self.a.free(outputs);

    // update cursors
    assert(inputs.len == outputs.len);
    for (outputs, 0..) |p, i| cm.cursors.values()[i].setActiveAnchor(cm, p.line, p.col);

    ///////////////////////////// Update CapList

    var linenr_map = EditLinenrMap.init(self.a);
    try linenr_map.ensureTotalCapacity(512);
    defer linenr_map.deinit();

    var replace_info_list = try ReplaceInfoList.initCapacity(a, inputs.len);

    for (0..inputs.len) |i| {
        assert(outputs[i].line >= inputs[i].start.line);
        const info = ReplaceInfo{
            .replace_start = inputs[i].start.line,
            .replace_len = inputs[i].end.line - inputs[i].start.line + 1,
            .start_line = outputs[i].line,
            .end_line = outputs[i].line,
        };
        if (self.buf.tstree != null) try self.updateCapList(info);
        try replace_info_list.append(info);
        try linenr_map.put(@intCast(outputs[i].line), {});
    }

    try self.updateWithTreeSitterRanges(ts_ranges, &linenr_map, &replace_info_list);
    return try replace_info_list.toOwnedSlice();
}

fn updateWithTreeSitterRanges(self: *@This(), ts_ranges: ?[]const LangSuite.ts.Range, map: *EditLinenrMap, replace_info_list: *ReplaceInfoList) !void {
    const ranges = ts_ranges orelse return;
    for (ranges) |r| {
        var may_start: ?usize = null;
        var may_end: ?usize = null;

        for (@intCast(r.start_point.row)..@intCast(r.end_point.row + 1)) |linenr| {
            if (map.contains(@intCast(linenr))) continue;
            try map.put(@intCast(linenr), {});
            may_end = linenr;
            if (may_start == null) may_start = linenr;
        }

        if (may_start) |start| {
            assert(may_end != null);
            const end = may_end orelse return;
            const info = ReplaceInfo{
                .replace_start = start,
                .replace_len = end - start + 1,
                .start_line = start,
                .end_line = end,
            };
            assert(self.buf.tstree != null);
            try self.updateCapList(info);
            try replace_info_list.append(info);
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// StoredCapture

pub const StoredCapture = struct {
    query_index: u16,
    capture_id: u16,
    start_col: u32,
    end_col: u32,

    fn lessThan(_: void, a: StoredCapture, b: StoredCapture) bool {
        if (a.start_col < b.start_col) return true;
        if (a.start_col == b.start_col) return a.end_col < b.end_col;
        return false;
    }
};

test {
    try eq(4, @alignOf(StoredCapture));
    try eq(12, @sizeOf(StoredCapture));
}

//////////////////////////////////////////////////////////////////////////////////////////////

const IDs = struct {
    query_id: u16,
    capture_id: u16,
};

pub const LineIterator = struct {
    col: usize = 0,
    contents: []const u8 = undefined,
    cp_iter: code_point.Iterator = undefined,

    captures_start: usize = 0,
    ids_buf: [8]IDs = undefined,

    pub fn init(ws: *const WindowSource, linenr: usize, buf: []u8) !LineIterator {
        var self = LineIterator{};
        var fba = std.heap.FixedBufferAllocator.init(buf);
        self.contents = try ws.buf.ropeman.getLineAlloc(fba.allocator(), linenr, buf.len);
        self.cp_iter = code_point.Iterator{ .bytes = self.contents };
        return self;
    }

    pub const Result = struct {
        ids: []const IDs,
        code_point: u21,
    };

    pub fn next(self: *@This(), captures: []StoredCapture) ?Result {
        const cp = self.cp_iter.next() orelse return null;
        if (cp.code == '\n') return null;
        if (captures.len == 0) return Result{ .ids = &.{}, .code_point = cp.code };

        defer self.col += 1;

        var ids_index: usize = 0;
        for (captures[self.captures_start..], 0..) |cap, i| {
            if (cap.start_col > self.col) break;

            if (cap.end_col <= self.col) {
                self.captures_start = i + 1;
                continue;
            }

            self.ids_buf[ids_index] = IDs{ .capture_id = cap.capture_id, .query_id = cap.query_index };
            ids_index += 1;
        }

        return Result{
            .ids = self.ids_buf[0..ids_index],
            .code_point = cp.code,
        };
    }
};

test LineIterator {
    var lang_hub = try LangSuite.LangHub.init(testing_allocator);
    defer lang_hub.deinit();
    {
        var ws = try WindowSource.create(testing_allocator, .file, "src/window/fixtures/dummy_3_lines.zig", &lang_hub);
        defer ws.destroy();
        try eqStr("const a = 10;\nvar not_false = true;\nconst Allocator = std.mem.Allocator;\n", try ws.buf.ropeman.toString(idc_if_it_leaks, .lf));

        try testLineIter(ws, 0, &.{
            .{ "const", &.{"type.qualifier"} },
            .{ " ", &.{} },
            .{ "a", &.{"variable"} },
            .{ " = ", &.{} },
            .{ "10", &.{"number"} },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
        try testLineIter(ws, 1, &.{
            .{ "var", &.{"type.qualifier"} },
            .{ " ", &.{} },
            .{ "not_false", &.{"variable"} },
            .{ " = ", &.{} },
            .{ "true", &.{"boolean"} },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
        try testLineIter(ws, 2, &.{
            .{ "const", &.{"type.qualifier"} },
            .{ " ", &.{} },
            .{ "Allocator", &.{ "variable", "type" } },
            .{ " = ", &.{} },
            .{ "std", &.{"variable"} },
            .{ ".", &.{"punctuation.delimiter"} },
            .{ "mem", &.{"field"} },
            .{ ".", &.{"punctuation.delimiter"} },
            .{ "Allocator", &.{ "field", "type" } },
            .{ ";", &.{"punctuation.delimiter"} },
            null,
        });
    }
}

const Expected = struct { []const u8, []const []const u8 };

fn testLineIter(ws: *const WindowSource, line: usize, exp: []const ?Expected) !void {
    const captures = ws.cap_list.items[line];
    var buf: [1024]u8 = undefined;
    var iter = try LineIterator.init(ws, line, &buf);
    for (exp, 0..) |may_e, clump_index| {
        if (may_e == null) {
            try eq(null, iter.next(captures));
            return;
        }
        const e = may_e.?;
        for (e[0]) |char| {
            const result = iter.next(captures).?;
            errdefer {
                std.debug.print("failed at line '{d}' | clump_index = '{d}'\n", .{ line, clump_index });
                for (0..result.ids.len) |i| {
                    const r = result.ids[i];
                    const capture_name = ws.ls.?.queries.values()[r.query_id].query.getCaptureNameForId(r.capture_id);
                    std.debug.print("missed capture name: '{s}';\n", .{capture_name});
                }
            }
            try eq(@as(u21, @intCast(char)), result.code_point);
            try eq(e[1].len, result.ids.len);
            for (0..result.ids.len) |i| {
                const r = result.ids[i];
                const capture_name = ws.ls.?.queries.values()[r.query_id].query.getCaptureNameForId(r.capture_id);
                try eqStr(e[1][i], capture_name);
            }
        }
    }
}
