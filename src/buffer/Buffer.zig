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

const Buffer = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const idc_if_it_leaks = std.heap.page_allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const eqSlice = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const RopeMan = @import("RopeMan");
const CursorPoint = RopeMan.CursorPoint;
const LangSuite = @import("LangSuite");
const ts = LangSuite.ts;

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
ropeman: RopeMan,

langsuite: ?*LangSuite = null,
tsparser: ?*ts.Parser = null,
tstree: ?*ts.Tree = null,

parse_buf: [PARSE_BUFFER_SIZE]u8 = undefined,
const PARSE_BUFFER_SIZE = 1024;

pub fn create(a: Allocator, from: RopeMan.InitFrom, source: []const u8) !*Buffer {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .ropeman = try RopeMan.initFrom(a, from, source),
    };
    return self;
}

pub fn destroy(self: *@This()) void {
    if (self.tsparser) |parser| parser.destroy();
    if (self.tstree) |tree| tree.destroy();
    self.ropeman.deinit();
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// initiateTreeSitter

pub fn initiateTreeSitter(self: *@This(), langsuite: *LangSuite) !void {
    self.langsuite = langsuite;
    self.tsparser = try self.langsuite.?.createParser();
    _ = self.parse();
}

test initiateTreeSitter {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    var buf = try Buffer.create(testing_allocator, .string, "const a = 10;");
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    try eqStr(
        \\source_file
        \\  Decl
        \\    VarDecl
        \\      "const"
        \\      IDENTIFIER
        \\      "="
        \\      ErrorUnionExpr
        \\        SuffixExpr
        \\          INTEGER
        \\      ";"
    , try buf.tstree.?.getRootNode().debugPrint());
}

////////////////////////////////////////////////////////////////////////////////////////////// insertChars

pub fn insertChars(self: *@This(), a: Allocator, chars: []const u8, destinations: []const CursorPoint) !struct { []CursorPoint, ?[]const ts.Range } {
    assert(chars.len > 0);
    assert(destinations.len > 0);
    if (destinations.len == 0) return .{ &.{}, null };

    const new_cursor_points = try self.ropeman.insertChars(a, chars, destinations);
    if (self.tstree == null) return .{ new_cursor_points, null };

    for (0..destinations.len) |i| try self.editSyntaxTreeInsert(destinations[i], new_cursor_points[i]);
    return .{ new_cursor_points, self.parse() };
}

fn editSyntaxTreeInsert(self: *@This(), start_cp: CursorPoint, end_cp: CursorPoint) !void {
    const start_point = ts.Point{ .row = @intCast(start_cp.line), .column = @intCast(start_cp.col) };
    const start_byte = try RopeMan.getByteOffsetOfPosition(self.ropeman.root, start_cp.line, start_cp.col);

    const old_end_byte = start_byte;
    const old_end_point = start_point;

    const new_end_byte = try RopeMan.getByteOffsetOfPosition(self.ropeman.root, end_cp.line, end_cp.col);
    const new_end_point = ts.Point{ .row = @intCast(end_cp.line), .column = @intCast(end_cp.col) };

    const edit = ts.InputEdit{
        .start_byte = @intCast(start_byte),
        .old_end_byte = @intCast(old_end_byte),
        .new_end_byte = @intCast(new_end_byte),
        .start_point = start_point,
        .old_end_point = old_end_point,
        .new_end_point = new_end_point,
    };
    self.tstree.?.edit(&edit);
}

test "insertChars - 1 single cursor" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    var buf = try Buffer.create(testing_allocator, .string, "const a = 10;");
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.insertChars(testing_allocator, "// ", &.{CursorPoint{ .line = 0, .col = 0 }});
    defer testing_allocator.free(e1_points);
    try eqStr("// const a = 10;", try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{.{ .line = 0, .col = 3 }}, e1_points);
    try eqSlice(ts.Range, &.{.{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 0, .column = 16 }, .start_byte = 0, .end_byte = 16 }}, e1_ts_ranges.?);
    try eqStr(
        \\source_file
        \\  line_comment
    , try buf.tstree.?.getRootNode().debugPrint());
}

test "insertChars - 3 cursors - case 1" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    const source =
        \\const a = 10;
        \\const b = 20;
        \\const c = 50;
    ;
    var buf = try Buffer.create(testing_allocator, .string, source);
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.insertChars(testing_allocator, "// ", &.{
        CursorPoint{ .line = 0, .col = 0 },
        CursorPoint{ .line = 1, .col = 0 },
        CursorPoint{ .line = 2, .col = 0 },
    });
    defer testing_allocator.free(e1_points);
    try eqStr(
        \\// const a = 10;
        \\// const b = 20;
        \\// const c = 50;
    , try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{
        .{ .line = 0, .col = 3 },
        .{ .line = 1, .col = 3 },
        .{ .line = 2, .col = 3 },
    }, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 0, .column = 16 }, .start_byte = 0, .end_byte = 16 },
        .{ .start_point = .{ .row = 1, .column = 0 }, .end_point = .{ .row = 1, .column = 16 }, .start_byte = 17, .end_byte = 33 },
        .{ .start_point = .{ .row = 2, .column = 0 }, .end_point = .{ .row = 2, .column = 16 }, .start_byte = 34, .end_byte = 50 },
    }, e1_ts_ranges.?);
    try eqStr(
        \\source_file
        \\  line_comment
        \\  line_comment
        \\  line_comment
    , try buf.tstree.?.getRootNode().debugPrint());
}

test "insertChars - 3 cursors - case 2" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    const source =
        \\const a = 10;
        \\const b = 20;
        \\
        \\const c = 50;
    ;
    var buf = try Buffer.create(testing_allocator, .string, source);
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.insertChars(testing_allocator, "// ", &.{
        CursorPoint{ .line = 0, .col = 0 },
        CursorPoint{ .line = 1, .col = 0 },
        CursorPoint{ .line = 3, .col = 0 },
    });
    defer testing_allocator.free(e1_points);
    try eqStr(
        \\// const a = 10;
        \\// const b = 20;
        \\
        \\// const c = 50;
    , try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{
        .{ .line = 0, .col = 3 },
        .{ .line = 1, .col = 3 },
        .{ .line = 3, .col = 3 },
    }, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 0, .column = 16 }, .start_byte = 0, .end_byte = 16 },
        .{ .start_point = .{ .row = 1, .column = 0 }, .end_point = .{ .row = 1, .column = 16 }, .start_byte = 17, .end_byte = 33 },
        .{ .start_point = .{ .row = 3, .column = 0 }, .end_point = .{ .row = 3, .column = 16 }, .start_byte = 35, .end_byte = 51 },
    }, e1_ts_ranges.?);
    try eqStr(
        \\source_file
        \\  line_comment
        \\  line_comment
        \\  line_comment
    , try buf.tstree.?.getRootNode().debugPrint());
}

test "insertChars - 3 cursors - case 3" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    const source =
        \\const a = 10;
        \\const b = 20;
        \\
        \\const c = 50;
    ;
    var buf = try Buffer.create(testing_allocator, .string, source);
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.insertChars(testing_allocator, "//", &.{
        CursorPoint{ .line = 0, .col = 0 },
        CursorPoint{ .line = 1, .col = 0 },
        CursorPoint{ .line = 3, .col = 13 },
    });
    defer testing_allocator.free(e1_points);
    try eqStr(
        \\//const a = 10;
        \\//const b = 20;
        \\
        \\const c = 50;//
    , try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{
        .{ .line = 0, .col = 2 },
        .{ .line = 1, .col = 2 },
        .{ .line = 3, .col = 15 },
    }, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 0, .column = 15 }, .start_byte = 0, .end_byte = 15 },
        .{ .start_point = .{ .row = 1, .column = 0 }, .end_point = .{ .row = 1, .column = 15 }, .start_byte = 16, .end_byte = 31 },
        .{ .start_point = .{ .row = 3, .column = 13 }, .end_point = .{ .row = 3, .column = 15 }, .start_byte = 46, .end_byte = 48 },
    }, e1_ts_ranges.?);
    try eqStr(
        \\source_file
        \\  line_comment
        \\  line_comment
        \\  Decl
        \\    VarDecl
        \\      "const"
        \\      IDENTIFIER
        \\      "="
        \\      ErrorUnionExpr
        \\        SuffixExpr
        \\          INTEGER
        \\      ";"
        \\  line_comment
    , try buf.tstree.?.getRootNode().debugPrint());
}

////////////////////////////////////////////////////////////////////////////////////////////// deleteRanges

pub fn deleteRanges(self: *@This(), a: Allocator, ranges: []const RopeMan.CursorRange) !struct { []CursorPoint, ?[]const ts.Range } {
    assert(ranges.len > 0);
    if (ranges.len == 0) return .{ &.{}, null };

    const old_node = self.ropeman.root;
    const new_cursor_points = try self.ropeman.deleteRanges(a, ranges);
    if (self.tstree == null) return .{ new_cursor_points, null };

    for (0..ranges.len) |i| try self.editSyntaxTreeDelete(old_node, ranges[i], new_cursor_points[i]);
    return .{ new_cursor_points, self.parse() };
}

fn editSyntaxTreeDelete(self: *@This(), old_node: RopeMan.RcNode, range: RopeMan.CursorRange, new_cp: CursorPoint) !void {
    const start_point = ts.Point{ .row = @intCast(range.start.line), .column = @intCast(range.start.col) };
    const old_end_point = ts.Point{ .row = @intCast(range.end.line), .column = @intCast(range.end.col) };

    const start_byte = try RopeMan.getByteOffsetOfPosition(old_node, range.start.line, range.start.col);
    const old_end_byte = try RopeMan.getByteOffsetOfPosition(old_node, range.end.line, range.end.col);

    const new_end_byte = start_byte;
    const new_end_point = ts.Point{ .row = @intCast(new_cp.line), .column = @intCast(new_cp.col) };

    const edit = ts.InputEdit{
        .start_byte = @intCast(start_byte),
        .old_end_byte = @intCast(old_end_byte),
        .new_end_byte = @intCast(new_end_byte),
        .start_point = start_point,
        .old_end_point = old_end_point,
        .new_end_point = new_end_point,
    };
    self.tstree.?.edit(&edit);
}

test "deleteRanges - 1 single cursor" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    var buf = try Buffer.create(testing_allocator, .string, "const a = 10;");
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.deleteRanges(testing_allocator, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 6 } },
    });
    defer testing_allocator.free(e1_points);
    try eqStr("a = 10;", try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{.{ .line = 0, .col = 0 }}, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 0, .column = 7 }, .start_byte = 0, .end_byte = 7 },
    }, e1_ts_ranges.?);
    try eqStr(
        \\source_file
        \\  ContainerField
        \\    ErrorUnionExpr
        \\      SuffixExpr
        \\        IDENTIFIER
        \\    "="
        \\    ErrorUnionExpr
        \\      SuffixExpr
        \\        INTEGER
        \\  ERROR
        \\    ";"
    , try buf.tstree.?.getRootNode().debugPrint());
}

const three_happy_consts =
    \\source_file
    \\  Decl
    \\    VarDecl
    \\      "const"
    \\      IDENTIFIER
    \\      "="
    \\      ErrorUnionExpr
    \\        SuffixExpr
    \\          INTEGER
    \\      ";"
    \\  Decl
    \\    VarDecl
    \\      "const"
    \\      IDENTIFIER
    \\      "="
    \\      ErrorUnionExpr
    \\        SuffixExpr
    \\          INTEGER
    \\      ";"
    \\  Decl
    \\    VarDecl
    \\      "const"
    \\      IDENTIFIER
    \\      "="
    \\      ErrorUnionExpr
    \\        SuffixExpr
    \\          INTEGER
    \\      ";"
;

test "deleteRanges - 3 cursors - case 1" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    const source =
        \\xconst a = 10;
        \\xconst b = 20;
        \\xconst c = 50;
    ;
    var buf = try Buffer.create(testing_allocator, .string, source);
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.deleteRanges(testing_allocator, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 } },
        .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 1 } },
        .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 2, .col = 1 } },
    });
    defer testing_allocator.free(e1_points);
    try eqStr(
        \\const a = 10;
        \\const b = 20;
        \\const c = 50;
    , try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 1, .col = 0 },
        .{ .line = 2, .col = 0 },
    }, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 1, .column = 0 }, .start_byte = 0, .end_byte = 15 },
        .{ .start_point = .{ .row = 2, .column = 0 }, .end_point = .{ .row = 2, .column = 13 }, .start_byte = 28, .end_byte = 41 },
    }, e1_ts_ranges.?);
    try eqStr(three_happy_consts, try buf.tstree.?.getRootNode().debugPrint());
}

test "deleteRanges - 3 cursors - case 2" {
    var ls = try LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    const source =
        \\xconstx a = 10;
        \\xconstx b = 20;
        \\xconstx c = 50;
    ;
    var buf = try Buffer.create(testing_allocator, .string, source);
    defer buf.destroy();
    try buf.initiateTreeSitter(ls);

    const e1_points, const e1_ts_ranges = try buf.deleteRanges(testing_allocator, &.{
        .{ .start = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 1 } },
        .{ .start = .{ .line = 0, .col = 6 }, .end = .{ .line = 0, .col = 7 } },
        .{ .start = .{ .line = 1, .col = 0 }, .end = .{ .line = 1, .col = 1 } },
        .{ .start = .{ .line = 1, .col = 6 }, .end = .{ .line = 1, .col = 7 } },
        .{ .start = .{ .line = 2, .col = 0 }, .end = .{ .line = 2, .col = 1 } },
        .{ .start = .{ .line = 2, .col = 6 }, .end = .{ .line = 2, .col = 7 } },
    });
    defer testing_allocator.free(e1_points);
    try eqStr(
        \\const a = 10;
        \\const b = 20;
        \\const c = 50;
    , try buf.ropeman.toString(idc_if_it_leaks, .lf));
    try eqSlice(CursorPoint, &.{
        .{ .line = 0, .col = 0 },
        .{ .line = 0, .col = 5 },
        .{ .line = 1, .col = 0 },
        .{ .line = 1, .col = 5 },
        .{ .line = 2, .col = 0 },
        .{ .line = 2, .col = 5 },
    }, e1_points);
    try eqSlice(ts.Range, &.{
        .{ .start_point = .{ .row = 0, .column = 0 }, .end_point = .{ .row = 2, .column = 13 }, .start_byte = 0, .end_byte = 41 },
    }, e1_ts_ranges.?);
    try eqStr(three_happy_consts, try buf.tstree.?.getRootNode().debugPrint());
}

////////////////////////////////////////////////////////////////////////////////////////////// parse

fn parse(self: *@This()) ?[]const ts.Range {
    assert(self.tsparser != null);

    const may_old_tree = self.tstree;
    defer if (may_old_tree) |old_tree| old_tree.destroy();

    const input: ts.Input = .{
        .payload = self,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, ts_point: ts.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                const ctx: *Buffer = @ptrCast(@alignCast(payload orelse return ""));
                const result = ctx.ropeman.dump(
                    .{ .line = @intCast(ts_point.row), .col = @intCast(ts_point.column) },
                    &ctx.parse_buf,
                    PARSE_BUFFER_SIZE,
                );

                bytes_read.* = @intCast(result.len);
                return @ptrCast(result.ptr);
            }
        }.read,
        .encoding = .utf_8,
    };

    const new_tree = self.tsparser.?.parse(may_old_tree, input) catch |err| switch (err) {
        error.NoLanguage => @panic("got error.NoLanguage despite having a non-null parser"),
        error.Unknown => {
            std.log.err("encountered Unknown error in parse(), destroying buffer's tree and parser.\n", .{});
            if (self.tstree) |tree| {
                tree.destroy();
                self.tstree = null;
            }
            if (self.tsparser) |parser| {
                parser.destroy();
                self.tsparser = null;
            }
            return null;
        },
    };
    self.tstree = new_tree;

    if (may_old_tree) |old_tree| return old_tree.getChangedRanges(new_tree);
    return null;
}
