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
    self.ropeman.deinit();
    self.a.destroy(self);
}

pub fn initiateTreeSitter(self: *@This(), langsuite: *LangSuite) !void {
    self.langsuite = langsuite;
    self.tsparser = try self.langsuite.?.newParser();
    _ = self.parse();
}

pub fn parse(self: *@This()) !void {
    assert(self.tsparser != null);

    const may_old_tree = self.tstree;
    defer if (may_old_tree) |old_tree| old_tree.destroy();

    const input: ts.Input = .{
        .payload = self,
        .read = struct {
            fn read(payload: ?*anyopaque, _: u32, ts_point: ts.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                const ctx: *Buffer = @ptrCast(@alignCast(payload orelse return ""));
                const result = ctx.ropeman.dump(
                    .{ .line = @intCast(ts_point.row), .col = @intCast(ts_point.col) },
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

//////////////////////////////////////////////////////////////////////////////////////////////

test Buffer {
    var buf = try Buffer.create(testing_allocator, .string, "hello there");
    defer buf.destroy();
}
