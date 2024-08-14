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

    const camera = rl.Camera3D{
        .position = .{ .x = 0, .y = 10, .z = 10 },
        .target = .{ .x = 0, .y = 0, .z = 0 },
        .up = .{ .x = 0, .y = 1, .z = 0 },
        .fovy = 45,
        .projection = .camera_perspective,
    };

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Update

        // TODO:

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);
            {
                // TODO:
                rl.beginMode3D(camera);
                defer rl.endMode3D();
                rl.drawGrid(10, 1);
            }
        }
    }
}

fn drawCodePoint3D(font: rl.Font, code_point: i32, pos: rl.Vector3, font_size: i32, backface: bool, tint: rl.Color) void {
    const index = rl.getGlyphIndex(font, code_point);
    const scale = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(font.baseSize));

    pos.x += (font.glyphs[index].offsetX - font.glyphPadding) / (font.baseSize * scale);
    pos.y += (font.glyphs[index].offsetY - font.glyphPadding) / (font.baseSize * scale);

    const src_rectangle = rl.Rectangle{
        .x = font.recs[index].x - font.glyphPadding,
        .y = font.recs[index].y - font.glyphPadding,
        .width = font.recs[index].width + 2 * font.glyphPadding,
        .height = font.recs[index].height + 2 * font.glyphPadding,
    };
    const width = (font.recs[index].width + 2 * font.glyphPadding) / (font.baseSize * scale);
    const height = (font.recs[index].height + 2 * font.glyphPadding) / (font.baseSize * scale);

    if (font.texture.id > 0) {
        defer rl.gl.rlSetTexture(0);

        const x: f32 = 0;
        const y: f32 = 0;
        const z: f32 = 0;

        const tx: f32 = src_rectangle.x / font.texture.width;
        const ty: f32 = src_rectangle.y / font.texture.height;
        const tw: f32 = (src_rectangle.x + src_rectangle.width) / font.texture.width;
        const th: f32 = (src_rectangle.y + src_rectangle.height) / font.texture.height;

        rl.gl.rlCheckRenderBatchLimit(4 + 4 * @as(i32, @intCast(@intFromBool(backface))));
        rl.gl.rlSetTexture(font.texture.id);

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
                    rl.gl.rlNormal3f(0, 1, 0);

                    rl.gl.rlTexCoord2f(tx, ty);
                    rl.gl.rlVertex3f(x, y, z);

                    rl.gl.rlTexCoord2f(tx, th);
                    rl.gl.rlVertex3f(x, y, z + height);

                    rl.gl.rlTexCoord2f(tw, th);
                    rl.gl.rlVertex3f(x + width, y, z + height);

                    rl.gl.rlTexCoord2f(tw, ty);
                    rl.gl.rlVertex3f(x + width, y, z);

                    return;
                }

                {
                    rl.gl.rlNormal3f(0, -1, 0);

                    rl.gl.rlTexCoord2f(tx, ty);
                    rl.gl.rlVertex3f(x, y, z);

                    rl.gl.rlTexCoord2f(tw, ty);
                    rl.gl.rlVertex3f(x + width, y, z);

                    rl.gl.rlTexCoord2f(tw, th);
                    rl.gl.rlVertex3f(x + width, y, z + height);

                    rl.gl.rlTexCoord2f(tx, th);
                    rl.gl.rlVertex3f(x, y, z + height);
                }
            }
        }
    }
}
