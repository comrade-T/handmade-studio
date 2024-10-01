const std = @import("std");
pub const code_point = rope.code_point;
const ztracy = @import("ztracy");

const rope = @import("rope");
pub const sitter = @import("ts");
pub const ts = sitter.b;
pub const PredicatesFilter = @import("ts").PredicatesFilter;
pub const SupportedLanguages = sitter.SupportedLanguages;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

pub const Buffer = struct {
    exa: Allocator,
    rope_arena: ArenaAllocator,

    roperoot: *const rope.Node,

    langsuite: ?*sitter.LangSuite = null,
    tsparser: ?*ts.Parser = null,
    tstree: ?*ts.Tree = null,

    parse_buf: [PARSE_BUFFER_SIZE + 1]u8 = undefined,
    const PARSE_BUFFER_SIZE = 1023; // leave 1 for potential \n

    pub fn create(external_allocator: Allocator, from: enum { string, file }, source: []const u8) !*@This() {
        const zone = ztracy.ZoneNC(@src(), "Buffer.create()", 0xFFAAFF);
        defer zone.End();

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

    const NewCursorPosition = struct { line: usize, col: usize };
    pub fn insertChars(self: *@This(), chars: []const u8, line: usize, col: usize) !struct { NewCursorPosition, ?[]const ts.Range } {
        const zone = ztracy.ZoneNC(@src(), "Buffer.insertChars()", 0xFFFFFF);
        defer zone.End();

        const start_point = ts.Point{ .row = @intCast(line), .column = @intCast(col) };
        const start_byte = try self.roperoot.getByteOffsetOfPosition(line, col);

        self.roperoot, const num_of_new_lines, const last_new_leaf_noc =
            try self.roperoot.insertChars(self.rope_arena.allocator(), start_byte, chars);
        self.roperoot = try self.roperoot.balance(self.rope_arena.allocator());

        var new_col = last_new_leaf_noc;
        if (num_of_new_lines == 0) new_col = col + last_new_leaf_noc;

        if (self.tstree == null) return .{ NewCursorPosition{ .line = line + num_of_new_lines, .col = new_col }, null };

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
        const ranges = try self.parse();
        return .{ NewCursorPosition{ .line = line + num_of_new_lines, .col = new_col }, ranges };
    }
    test insertChars {
        // Insert only
        {
            {
                const buf = try Buffer.create(testing_allocator, .string, "const str =;");
                defer buf.destroy();
                {
                    const new_pos, _ = try buf.insertChars("\n    \\\\hello\n    \\\\world\n", 0, 11);
                    try eq(3, new_pos.line);
                    try eq(0, new_pos.col);
                    const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                    try eqStr(
                        \\const str =
                        \\    \\hello
                        \\    \\world
                        \\;
                    , content.items);
                }
                {
                    const new_pos, _ = try buf.insertChars(" my", 1, 11);
                    try eq(1, new_pos.line);
                    try eq(14, new_pos.col);
                    const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                    try eqStr(
                        \\const str =
                        \\    \\hello my
                        \\    \\world
                        \\;
                    , content.items);
                }
                {
                    const new_pos, _ = try buf.insertChars("!", 2, 11);
                    const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                    try eq(2, new_pos.line);
                    try eq(12, new_pos.col);
                    try eqStr(
                        \\const str =
                        \\    \\hello my
                        \\    \\world!
                        \\;
                    , content.items);
                }
            }
        }

        // Insert + Tree Sitter update
        {
            const langsuite = try sitter.LangSuite.create(testing_allocator, .zig);
            defer langsuite.destroy();
            {
                const buf = try Buffer.create(testing_allocator, .string, "const");
                defer buf.destroy();
                try buf.initiateTreeSitter(langsuite);
                {
                    const new_pos, _ = try buf.insertChars(" std", 0, 5);
                    try eq(0, new_pos.line);
                    try eq(9, new_pos.col);
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
            {
                const buf = try Buffer.create(testing_allocator, .string, "const");
                defer buf.destroy();
                try buf.initiateTreeSitter(langsuite);
                {
                    const new_pos, _ = try buf.insertChars("\n", 0, 5);
                    try eq(1, new_pos.line);
                    try eq(0, new_pos.col);
                    const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                    try eqStr(
                        \\const
                        \\
                    , content.items);
                }
                {
                    const new_pos, _ = try buf.insertChars("\n", 1, 0);
                    try eq(2, new_pos.line);
                    try eq(0, new_pos.col);
                    const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                    try eqStr(
                        \\const
                        \\
                        \\
                    , content.items);
                }
            }
        }
    }

    ///////////////////////////// Delete

    pub fn deleteRange(self: *@This(), a: struct { usize, usize }, b: struct { usize, usize }) !?[]const ts.Range {
        const zone = ztracy.ZoneNC(@src(), "Buffer.deleteRange()", 0x55AA55);
        defer zone.End();

        if (a[0] == b[0] and a[1] == b[1]) return null;

        const offset_a = try self.roperoot.getByteOffsetOfPosition(a[0], a[1]);
        const offset_b = try self.roperoot.getByteOffsetOfPosition(b[0], b[1]);

        var start_byte = offset_a;
        var old_end_byte = offset_b;
        if (offset_a > offset_b) {
            start_byte = offset_b;
            old_end_byte = offset_a;
        }

        self.roperoot = try self.roperoot.deleteBytes(self.rope_arena.allocator(), start_byte, old_end_byte - start_byte);

        if (self.tstree == null) return null;
        {
            var start_point = ts.Point{ .row = @intCast(a[0]), .column = @intCast(a[1]) };
            var old_end_point = ts.Point{ .row = @intCast(b[0]), .column = @intCast(b[1]) };
            if (offset_a > offset_b) {
                start_point = ts.Point{ .row = @intCast(b[0]), .column = @intCast(b[1]) };
                old_end_point = ts.Point{ .row = @intCast(a[0]), .column = @intCast(a[1]) };
            }

            const new_end_byte = start_byte;
            const new_end_point = start_point;

            const edit = ts.InputEdit{
                .start_byte = @intCast(start_byte),
                .old_end_byte = @intCast(old_end_byte),
                .new_end_byte = @intCast(new_end_byte),
                .start_point = start_point,
                .old_end_point = old_end_point,
                .new_end_point = new_end_point,
            };
            self.tstree.?.edit(&edit);
            return try self.parse();
        }

        return null;
    }
    test deleteRange {
        const langsuite = try sitter.LangSuite.create(testing_allocator, .zig);
        defer langsuite.destroy();
        { // content only
            {
                var buf = try Buffer.create(testing_allocator, .string, "const");
                defer buf.destroy();
                _ = try buf.deleteRange(.{ 0, 0 }, .{ 0, 1 });
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr("onst", content.items);
            }
            {
                var buf = try Buffer.create(testing_allocator, .string, "var\nc");
                defer buf.destroy();
                _ = try buf.deleteRange(.{ 1, 0 }, .{ 1, 1 });
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr("var\n", content.items);
            }
        }
        { // with Tree Sitter
            {
                var buf = try Buffer.create(testing_allocator, .string, "const std");
                defer buf.destroy();
                try buf.initiateTreeSitter(langsuite);
                try eqStr(
                    \\source_file
                    \\  Decl
                    \\    VarDecl
                    \\      "const"
                    \\      IDENTIFIER
                    \\      ";"
                , try buf.tstree.?.getRootNode().debugPrint());

                _ = try buf.deleteRange(.{ 0, 5 }, .{ 0, 9 });

                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr("const", content.items);
                try eqStr(
                    \\source_file
                    \\  ERROR
                    \\    "const"
                , try buf.tstree.?.getRootNode().debugPrint());
            }
            {
                var buf = try Buffer.create(testing_allocator, .string, "var\nc");
                defer buf.destroy();
                try buf.initiateTreeSitter(langsuite);
                _ = try buf.deleteRange(.{ 1, 0 }, .{ 1, 1 });
                const content = try buf.roperoot.getContent(buf.rope_arena.allocator());
                try eqStr("var\n", content.items);
            }
        }
    }

    ///////////////////////////// Tree Sitter Parsing

    fn parse(self: *@This()) !?[]const ts.Range {
        const zone = ztracy.ZoneNC(@src(), "Buffer.parse()", 0xFFFFFF);
        defer zone.End();

        if (self.tsparser == null) @panic("parse() is called on a Buffer with no parser!");

        const may_old_tree = self.tstree;
        defer if (may_old_tree) |old_tree| old_tree.destroy();

        const input: ts.Input = .{
            .payload = self,
            .read = struct {
                fn read(payload: ?*anyopaque, start_byte: u32, _: ts.Point, bytes_read: *u32) callconv(.C) [*:0]const u8 {
                    const ctx: *Buffer = @ptrCast(@alignCast(payload orelse return ""));
                    var result, const eol = ctx.roperoot.getRestOfLine(start_byte, &ctx.parse_buf, PARSE_BUFFER_SIZE);
                    if (eol) {
                        ctx.parse_buf[result.len] = '\n';
                        result = ctx.parse_buf[0 .. result.len + 1];
                    }
                    bytes_read.* = @intCast(result.len);
                    return @ptrCast(result.ptr);
                }
            }.read,
            .encoding = .utf_8,
        };

        const new_tree = try self.tsparser.?.parse(may_old_tree, input);
        defer self.tstree = new_tree;

        if (may_old_tree) |old_tree| return old_tree.getChangedRanges(new_tree);
        return null;
    }
    test parse {
        const langsuite = try sitter.LangSuite.create(testing_allocator, .zig);
        defer langsuite.destroy();
        {
            const source = "const a = 10;\nconst b = true;";
            var buf = try Buffer.create(testing_allocator, .string, source);
            defer buf.destroy();
            try buf.initiateTreeSitter(langsuite);
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
                \\  Decl
                \\    VarDecl
                \\      "const"
                \\      IDENTIFIER
                \\      "="
                \\      ErrorUnionExpr
                \\        SuffixExpr
                \\          "true"
                \\      ";"
            , try buf.tstree.?.getRootNode().debugPrint());
        }
    }

    pub fn initiateTreeSitter(self: *@This(), langsuite: *sitter.LangSuite) !void {
        self.langsuite = langsuite;
        self.tsparser = try self.langsuite.?.newParser();
        _ = try self.parse();
    }

    ///////////////////////////// Content Callback for PredicatesFilter

    pub fn contentCallback(ctx_: *anyopaque, start_byte: usize, end_byte: usize, buf: []u8, buf_size: usize) []const u8 {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_));
        return ctx.roperoot.getRange(start_byte, end_byte, buf, buf_size) catch "";
    }
};

test {
    std.testing.refAllDeclsRecursive(Buffer);
}
