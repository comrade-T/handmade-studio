const std = @import("std");
const rope = @import("rope");
const ts = @import("ts").b;

const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
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

fn getTSParser(lang: SupportedLanguages) !ts.Parser {
    const tslang: ts.Language = switch (lang) {
        .zig => ts.Language.get("zig"),
    };
    var parser = try ts.Parser.create();
    parser.setLanguage(tslang);
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
        const a = std.testing.allocator;
        const buf = try Buffer.create(a, .string, "hello");
        defer buf.destroy();
        try eq(null, buf.tsparser);
        try eq(null, buf.tstree);
    }

    pub fn destroy(self: *@This()) void {
        self.rope_arena.deinit();
        self.exa.destroy(self);
    }
};

test {
    std.testing.refAllDecls(Buffer);
}
