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

fn editSyntaxTreeInsert(self: *@This(), first_point: CursorPoint, last_point: CursorPoint) !void {
    const start_point = ts.Point{ .row = @intCast(first_point.line), .column = @intCast(first_point.col) };
    const start_byte = try self.ropeman.getByteOffsetOfPosition(first_point.line, first_point.col);

    const old_end_byte = start_byte;
    const old_end_point = start_point;

    const new_end_byte = try self.ropeman.getByteOffsetOfPosition(last_point.line, last_point.col);
    const new_end_point = ts.Point{ .row = @intCast(last_point.line), .column = @intCast(last_point.col) };

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
                ) catch "";
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
