const std = @import("std");
const rope = @import("rope");
const ts = @import("ts").b;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

// remember: multiple windows need to be able to require different views from the same Buffer.
// remember: Cursor is managed by Window, not Buffer.

// Tree Sitter tree should stay alongside a Rope (the content).
// The tree will update right after the Rope is updated.
// Tree tree is just the tree, no additional logic here.
// ==> If you want additional Tree Sitter schenanigans,
// you already have access to the lastest tree,
// use that tree yourself, don't pester the Buffer struct.

const SupportedLanguages = enum { zig };

fn getTSParser(lang: SupportedLanguages) !*ts.Parser {
    const tslang = switch (lang) {
        .zig => try ts.Language.get("zig"),
    };
    var parser = try ts.Parser.create();
    try parser.setLanguage(tslang);
    return parser;
}

pub const Buffer = struct {
    exa: Allocator,
    rope_arena: ArenaAllocator,

    roperoot: *const rope.Node,

    tsparser: ?*ts.Parser = null,
    tstree: ?*ts.Tree = null,

    pub fn create(external_allocator: Allocator, from: enum { string, file }, source: []const u8) !*@This() {
        var self = try external_allocator.create(@This());
        self.* = .{
            .exa = external_allocator,
            .rope_arena = ArenaAllocator.init(external_allocator),
            .roperoot = switch (from) {
                .string => try rope.Node.fromString(self.rope_arena.allocator(), source, true),
                .file => try rope.Node.fromFile(self.rope_arena.allocator(), source),
            },
        };
        return self;
    }
    test create {
        const buf = try Buffer.create(testing_allocator, .string, "hello");
        defer buf.destroy();
        try eq(null, buf.tsparser);
        try eq(null, buf.tstree);
    }

    pub fn destroy(self: *@This()) void {
        self.rope_arena.deinit();
        if (self.tsparser) |parser| parser.destroy();
        if (self.tstree) |tree| tree.destroy();
        defer self.exa.destroy(self);
    }

    ///////////////////////////// Insert

    fn insertChars(self: *@This(), chars: []const u8, line: usize, col: usize) !void {
        const start_point = ts.Point{ .row = @intCast(line), .column = @intCast(col) };
        const start_byte = try self.roperoot.getByteOffsetOfPosition(line, col);
        self.roperoot, const num_of_new_lines, const new_col = try self.roperoot.insertChars(self.rope_arena.allocator(), start_byte, chars);
        self.roperoot = try self.roperoot.balance(self.rope_arena.allocator());

        if (self.tstree == null) return;

        const old_end_byte = start_byte; // since it's insert operation, not delete or replace.
        const old_end_point = start_point;

        const new_end_byte = start_byte + chars.len;
        const new_end_point = ts.Point{ .row = @intCast(line + num_of_new_lines), .column = @intCast(new_col) };

        const edit = ts.InputEdit{
            .start_byte = @intCast(start_byte),
            .old_end_byte = @intCast(old_end_byte),
            .new_end_byte = @intCast(new_end_byte),
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = new_end_point,
        };

        self.tstree.?.edit(&edit);
        try self.parse();
    }
    test insertChars {
        // Insert only
        {
            const buf = try Buffer.create(testing_allocator, .string, "const str =;");
            defer buf.destroy();
            {
                try buf.insertChars("\n    \\\\hello\n    \\\\world\n", 0, 11);
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr(
                    \\const str =
                    \\    \\hello
                    \\    \\world
                    \\;
                , content.items);
            }
            {
                try buf.insertChars(" my", 1, 11);
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr(
                    \\const str =
                    \\    \\hello my
                    \\    \\world
                    \\;
                , content.items);
            }
            {
                try buf.insertChars("!", 2, 11);
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr(
                    \\const str =
                    \\    \\hello my
                    \\    \\world!
                    \\;
                , content.items);
            }
        }

        // Insert + Tree Sitter update
        {
            const buf = try Buffer.create(testing_allocator, .string, "const");
            defer buf.destroy();
            try buf.initiateTreeSitter(.zig);
            {
                try buf.insertChars(" std", 0, 5);
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr("const std", content.items);
                try eqStr(
                    \\source_file
                    \\  Decl
                    \\    VarDecl
                    \\      "const"
                    \\      IDENTIFIER
                    \\      ";"
                , try buf.tstree.?.getRootNode().debugPrint());
            }
        }
    }

    ///////////////////////////// Tree Sitter Parsing

    const PARSE_BUFFER_SIZE = 1024;

    fn parse(self: *@This()) !void {
        if (self.tsparser == null) @panic("parse() is called on a Buffer with no parser!");

        const may_old_tree = self.tstree;
        defer if (may_old_tree) |old_tree| old_tree.destroy();

        const input: ts.Input = .{
            .payload = self,
            .read = struct {
                fn read(payload: ?*anyopaque, start_byte: u32, _: ts.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                    var buf: [PARSE_BUFFER_SIZE]u8 = undefined;
                    const ctx: *Buffer = @ptrCast(@alignCast(payload orelse return ""));
                    const result = ctx.roperoot.getRestOfLine(start_byte, &buf, PARSE_BUFFER_SIZE);
                    bytes_read.* = @intCast(result.len);
                    return @ptrCast(result.ptr);
                }
            }.read,
            .encoding = .utf_8,
        };
        self.tstree = try self.tsparser.?.parse(self.tstree, input);
    }
    test parse {
        var buf = try Buffer.create(testing_allocator, .string, "const");
        defer buf.destroy();
        try buf.initiateTreeSitter(.zig);
        try eqStr(
            \\source_file
            \\  ERROR
            \\    "const"
        , try buf.tstree.?.getRootNode().debugPrint());
    }

    fn initiateTreeSitter(self: *@This(), lang: SupportedLanguages) !void {
        self.tsparser = try getTSParser(lang);
        try self.parse();
    }
};

test {
    std.testing.refAllDecls(Buffer);
}
