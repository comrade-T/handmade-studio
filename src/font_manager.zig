const std = @import("std");
const rl = @import("raylib");
const Allocator = std.mem.Allocator;

//////////////////////////////////////////////////////////////////////////////////////////////

const Glyph = struct {
    advanceX: i32,
    offsetX: i32,
    width: f32,
};

const GlyphMap = std.AutoArrayHashMap(i32, Glyph);

const ManagedFont = struct {
    a: Allocator,
    font: rl.Font,
    glyphs: GlyphMap,

    fn create(a: Allocator, path: [*:0]const u8, size: i32) !*@This() {
        const self = try a.create(@This());
        const character_set = null;
        const font = rl.loadFontEx(path, size, character_set);
        self.* = ManagedFont{
            .a = a,
            .font = font,
            .glyphs = try createGlyphMap(a, font),
        };
        return self;
    }

    fn destroy(self: *@This()) void {
        for (self.sizes.values()) |fws| fws.destroy();
        self.sizes.deinit();
        self.a.destroy(self);
    }

    fn createGlyphMap(a: Allocator, font: rl.Font) !GlyphMap {
        var map = GlyphMap.init(a);
        for (0..@intCast(font.glyphCount)) |i| {
            const rec = font.recs[i];
            const gi = font.glyphs[i];
            try map.put(gi.value, Glyph{ .width = rec.width, .offsetX = gi.offsetX, .advanceX = gi.advanceX });
        }
        return map;
    }
};

pub const FontManager = struct {
    a: Allocator,
    arena: std.heap.ArenaAllocator,
    fonts: ManagedFontMap,

    const ManagedFontMap = std.StringArrayHashMap(*ManagedFont);

    pub fn create(a: Allocator) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .fonts = ManagedFontMap.init(self.arena.allocator()),
        };
        return self;
    }

    pub fn addFontWithSize(self: *@This(), name: []const u8, path: [*:0]const u8, size: i32) !void {
        if (self.fonts.get(name)) |_| return;
        const mf = try ManagedFont.create(self.arena.allocator(), path, size);
        try self.fonts.put(name, mf);
    }

    pub fn destroy(self: *@This()) void {
        self.arena.deinit();
        self.a.destroy(self);
    }

    pub fn getGlyphInfo(ctx: *anyopaque, name: []const u8, code_point: u21) ?Glyph {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        if (self.fonts.get(name)) |mf| {
            if (mf.glyphs.get(@as(i32, @intCast(code_point)))) |glyph| return glyph;
        }
        return null;
    }
};
