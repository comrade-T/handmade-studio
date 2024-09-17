const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

const _vw = @import("virtuous_window");

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn generateFontData(a: Allocator, font: rl.Font) !_vw.FontData {
    var recs = try a.alloc(_vw.Rectangle, @intCast(font.glyphCount));
    var glyphs = try a.alloc(_vw.GlyphData, @intCast(font.glyphCount));

    for (0..@intCast(font.glyphCount)) |i| {
        recs[i] = _vw.Rectangle{
            .x = font.recs[i].x,
            .y = font.recs[i].y,
            .width = font.recs[i].width,
            .height = font.recs[i].height,
        };

        glyphs[i] = _vw.GlyphData{
            .advanceX = font.glyphs[i].advanceX,
            .offsetX = @intCast(font.glyphs[i].offsetX),
            .value = font.glyphs[i].value,
        };
    }

    return .{
        .base_size = font.baseSize,
        .glyph_padding = font.glyphPadding,
        .recs = recs,
        .glyphs = glyphs,
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

pub const ScreenView = struct {
    start: rl.Vector2 = .{ .x = 0, .y = 0 },
    end: rl.Vector2 = .{ .x = 0, .y = 0 },
    width: f32,
    height: f32,
    screen_width: f32,
    screen_height: f32,

    pub fn update(self: *@This(), camera: rl.Camera2D) void {
        self.start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
        self.end = rl.getScreenToWorld2D(.{ .x = self.screen_width, .y = self.screen_height }, camera);
        self.width = self.end.x - self.start.x;
        self.height = self.end.y - self.start.y;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn renderVirtuousWindow(
    window: *_vw.Window,
    font: rl.Font,
    font_size: i32,
    font_data: _vw.FontData,
    font_data_index_map: _vw.FontDataIndexMap,
    view: ScreenView,
) void {
    {
        var last_y: f32 = undefined;

        var iter = window.codePointIter(font_data, font_data_index_map, .{
            .start_x = view.start.x,
            .start_y = view.start.y,
            .end_x = view.end.x,
            .end_y = view.end.y,
        });

        while (iter.next()) |result| {
            switch (result) {
                .code_point => |char| {
                    rl.drawTextCodepoint(
                        font,
                        char.value,
                        .{ .x = char.x, .y = char.y },
                        @floatFromInt(font_size),
                        rl.Color.fromInt(char.color),
                    );

                    if (iter.current_line + window.contents.start_line == window.cursor.line) {
                        if (iter.current_col -| 1 == window.cursor.col) {
                            rl.drawRectangle(
                                @intFromFloat(char.x),
                                @intFromFloat(char.y),
                                @intFromFloat(char.char_width),
                                font_size,
                                rl.Color.ray_white,
                            );
                        }
                        if (iter.current_col == window.cursor.col) {
                            rl.drawRectangle(
                                @intFromFloat(char.x + char.char_width),
                                @intFromFloat(char.y),
                                @intFromFloat(char.char_width),
                                font_size,
                                rl.Color.ray_white,
                            );
                        }
                    }

                    last_y = char.y;
                },

                .skip_to_new_line => {
                    if (iter.current_line + window.contents.start_line == window.cursor.line and
                        window.contents.lines[iter.current_line].len == 0 and
                        iter.current_col == 0)
                    {
                        rl.drawRectangle(
                            @intFromFloat(window.x),
                            @intFromFloat(last_y + @as(f32, @floatFromInt(font_size))),
                            15,
                            font_size,
                            rl.Color.ray_white,
                        );
                    }
                    defer last_y += @as(f32, @floatFromInt(font_size));
                },
                else => continue,
            }
        }
    }
}
