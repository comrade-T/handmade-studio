const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() !void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true, .vsync_hint = true });

    rl.initWindow(screen_width, screen_height, "Camera3DExample");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Model

    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

    var camera = rl.Camera3D{
        .position = .{ .x = 0, .y = 10, .z = 10 },
        .target = .{ .x = 0, .y = 0, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 45,
        .projection = .camera_perspective,
    };

    rl.disableCursor();

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // TODO:
        rl.updateCamera(&camera, .camera_free);

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            {
                rl.beginMode3D(camera);
                defer rl.endMode3D();
                rl.drawGrid(10, 1);
                // rl.drawCube(.{ .x = 0, .y = 0, .z = 0 }, 2, 2, 2, rl.Color.sky_blue);
                {
                    // rl.gl.rlPushMatrix();
                    // defer rl.gl.rlPopMatrix();
                    drawChar3D(font, "z", .{ .x = 0, .y = 0, .z = 0 }, 40, false, rl.Color.yellow);
                    drawChar3D(font, "o", .{ .x = 1, .y = 0, .z = 1 }, 40, false, rl.Color.red);
                    drawChar3D(font, "o", .{ .x = 2, .y = 0, .z = 2 }, 40, false, rl.Color.blue);
                    drawChar3D(font, "m", .{ .x = 3, .y = 0, .z = 3 }, 40, false, rl.Color.white);
                }
            }
        }
    }
}

fn drawChar3D(
    font: rl.Font,
    char: [*:0]const u8,
    position: rl.Vector3,
    font_size: i32,
    backface: bool,
    tint: rl.Color,
) void {
    var code_point_byte_count: i32 = 0;
    const code_point = rl.getCodepoint(char, &code_point_byte_count);

    const index: usize = @intCast(rl.getGlyphIndex(font, code_point));
    const scale = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(font.baseSize));

    var pos = position;

    pos.x += @as(f32, @floatFromInt(font.glyphs[index].offsetX - font.glyphPadding)) / (@as(f32, @floatFromInt(font.baseSize)) * scale);
    pos.z += @as(f32, @floatFromInt(font.glyphs[index].offsetY - font.glyphPadding)) / (@as(f32, @floatFromInt(font.baseSize)) * scale);

    const base_size: f32 = @floatFromInt(font.baseSize);
    const glyph_padding: f32 = @floatFromInt(font.glyphPadding);

    const src_rectangle = rl.Rectangle{
        .x = font.recs[index].x - glyph_padding,
        .y = font.recs[index].y - glyph_padding,
        .width = font.recs[index].width + 2 * glyph_padding,
        .height = font.recs[index].height + 2 * glyph_padding,
    };
    const width = (font.recs[index].width + 2 * glyph_padding) / (base_size * scale);
    const height = (font.recs[index].height + 2 * glyph_padding) / (base_size * scale);

    rl.drawCubeWiresV(
        .{ .x = pos.x + width / 2, .y = pos.y, .z = pos.z + height / 2 },
        .{ .x = width, .y = 0.25, .z = height },
        rl.Color.ray_white,
    );

    if (font.texture.id > 0) {
        const x: f32 = 0;
        const y: f32 = 0;
        const z: f32 = 0;

        const font_texture_width: f32 = @floatFromInt(font.texture.width);
        const font_texture_height: f32 = @floatFromInt(font.texture.height);

        // normalized texture coordinates of the glyph inside the font texture (0.0f -> 1.0f)
        const tx: f32 = src_rectangle.x / font_texture_width;
        const ty: f32 = src_rectangle.y / font_texture_height;
        const tw: f32 = (src_rectangle.x + src_rectangle.width) / font_texture_width;
        const th: f32 = (src_rectangle.y + src_rectangle.height) / font_texture_height;

        const buf_overflow = rl.gl.rlCheckRenderBatchLimit(4 + 4 * @as(i32, @intCast(@intFromBool(backface))));
        if (buf_overflow) @panic("internal buffer overflow for a given number of vertex");

        rl.gl.rlSetTexture(font.texture.id);
        defer rl.gl.rlSetTexture(0);

        {
            rl.gl.rlPushMatrix();
            defer rl.gl.rlPopMatrix();

            rl.gl.rlTranslatef(pos.x, pos.y, pos.z);

            {
                const RL_QUADS = 0x0007;
                rl.gl.rlBegin(RL_QUADS);
                defer rl.gl.rlEnd();

                rl.gl.rlColor4ub(tint.r, tint.g, tint.b, tint.a);

                if (!backface) {
                    // Normal Pointing Up
                    rl.gl.rlNormal3f(0, 1, 0);

                    // Top Left Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tx, ty);
                    rl.gl.rlVertex3f(x, y, z);

                    // Bottom Left Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tx, th);
                    rl.gl.rlVertex3f(x, y, z + height);

                    // Bottom Right Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tw, th);
                    rl.gl.rlVertex3f(x + width, y, z + height);

                    // Top Right Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tw, ty);
                    rl.gl.rlVertex3f(x + width, y, z);

                    return;
                }

                {
                    // Normal Pointing Down
                    rl.gl.rlNormal3f(0, -1, 0);

                    // Top Right Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tx, ty);
                    rl.gl.rlVertex3f(x, y, z);

                    // Top Left Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tw, ty);
                    rl.gl.rlVertex3f(x + width, y, z);

                    // Bottom Left Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tw, th);
                    rl.gl.rlVertex3f(x + width, y, z + height);

                    // Bottom Right Of The Texture and Quad
                    rl.gl.rlTexCoord2f(tx, th);
                    rl.gl.rlVertex3f(x, y, z + height);
                }
            }
        }
    }
}
