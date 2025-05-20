const std = @import("std");
const rl = @import("raylib");

const FontStore = @import("FontStore");
const RenderMall = @import("RenderMall");

pub const FONT_BASE_SIZE = 100;

//////////////////////////////////////////////////////////////////////////////////////////////

pub const info_callbacks = RenderMall.InfoCallbacks{
    .getScreenWidthHeight = getScreenWidthHeight,
    .getScreenToWorld2D = getScreenToWorld2D,
    .getWorldToScreen2D = getWorldToScreen2D,
    .getViewFromCamera = getViewFromCamera,
    .getAbsoluteViewFromCamera = getAbsoluteViewFromCamera,
    .cameraTargetsEqual = cameraTargetsEqual,
    .getCameraZoom = getCameraZoom,
    .getCameraInfo = getCameraInfo,
    .calculateCameraTarget = calculateCameraTarget,
    .getViewFromCameraInfo = getViewFromCameraInfo,
};

pub const render_callbacks = RenderMall.RenderCallbacks{
    .drawCodePoint = drawCodePoint,
    .drawRectangle = drawRectangle,
    .drawRectangleLines = drawRectangleLines,
    .drawRectangleGradient = drawRectangleGradient,
    .drawCircle = drawCircle,
    .drawLine = drawLine,
    .changeCameraZoom = changeCameraZoom,
    .changeCameraPan = changeCameraPan,
    .setCameraPosition = setCameraPosition,
    .centerCameraAt = centerCameraAt,
    .setCamera = setCamera,
    .beginScissorMode = beginScissorMode,
    .endScissorMode = endScissorMode,
    .setClipboardText = setClipboardText,
    .setCameraPositionFromCameraInfo = setCameraPositionFromCameraInfo,

    .drawTexture = drawTexture,
    .unloadTexture = unloadTexture,
    .loadImage = loadImage,
};

////////////////////////////////////////////////////////////////////////////////////////////// Render Callbacks

pub fn drawTexture(tex: *anyopaque, x: f32, y: f32, rotation: f32, scale: f32) void {
    const texture = @as(*rl.Texture2D, @ptrCast(@alignCast(tex)));
    rl.drawTextureEx(texture.*, .{ .x = x, .y = y }, rotation, scale, rl.Color.white);
}

pub fn unloadTexture(a: std.mem.Allocator, tex: *anyopaque) void {
    const texture = @as(*rl.Texture2D, @ptrCast(@alignCast(tex)));
    defer a.destroy(texture);
    rl.unloadTexture(texture.*);
}

pub fn loadImage(a: std.mem.Allocator, path: [:0]const u8) !RenderMall.Image {
    const tex = try a.create(rl.Texture2D);
    tex.* = try rl.loadTexture(path);
    return RenderMall.Image{
        .texture = tex,
        .width = @floatFromInt(tex.width),
        .height = @floatFromInt(tex.height),
    };
}

pub fn drawCodePoint(font: *const FontStore.Font, code_point: u21, x: f32, y: f32, font_size: f32, color: u32) void {
    std.debug.assert(font.rl_font != null);
    const rl_font = @as(*rl.Font, @ptrCast(@alignCast(font.rl_font)));
    rl.drawTextCodepoint(rl_font.*, @intCast(code_point), .{ .x = x, .y = y }, font_size, rl.Color.fromInt(color));
}

pub fn drawRectangle(x: f32, y: f32, width: f32, height: f32, color: u32) void {
    rl.drawRectangle(
        @as(i32, @intFromFloat(x)),
        @as(i32, @intFromFloat(y)),
        @as(i32, @intFromFloat(width)),
        @as(i32, @intFromFloat(height)),
        rl.Color.fromInt(color),
    );
}

pub fn drawRectangleLines(x: f32, y: f32, width: f32, height: f32, line_thick: f32, color: u32) void {
    rl.drawRectangleLinesEx(
        .{ .x = x, .y = y, .width = width, .height = height },
        line_thick,
        rl.Color.fromInt(color),
    );
}

pub fn drawRectangleGradient(x: f32, y: f32, width: f32, height: f32, top_left: u32, bottom_left: u32, bottom_right: u32, top_right: u32) void {
    // TODO: add color pickers to change backgrounds

    rl.drawRectangleGradientEx(
        .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        },
        // rl.Color.red,
        // rl.Color.blue,
        // rl.Color.purple,
        // rl.Color.yellow,
        rl.Color.fromInt(top_left),
        rl.Color.fromInt(bottom_left),
        rl.Color.fromInt(bottom_right),
        rl.Color.fromInt(top_right),
    );
    // _ = top_left;
    // _ = bottom_left;
    // _ = top_right;
    // _ = bottom_right;
}

pub fn drawCircle(x: f32, y: f32, radius: f32, color: u32) void {
    rl.drawCircleV(.{ .x = x, .y = y }, radius, rl.Color.fromInt(color));
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, color: u32) void {
    rl.drawLineEx(
        .{ .x = start_x, .y = start_y },
        .{ .x = end_x, .y = end_y },
        thickness,
        rl.Color.fromInt(color),
    );
}

pub fn changeCameraZoom(camera_: *anyopaque, target_camera_: *anyopaque, x: f32, y: f32, scale_factor: f32) void {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));

    const anchor_world_pos = rl.getScreenToWorld2D(.{ .x = x, .y = y }, camera.*);

    camera.offset = rl.Vector2{ .x = x, .y = y };
    target_camera.offset = rl.Vector2{ .x = x, .y = y };

    target_camera.target = anchor_world_pos;
    camera.target = anchor_world_pos;

    target_camera.zoom = rl.math.clamp(target_camera.zoom * scale_factor, 0.125, 64);
}

pub fn changeCameraPan(target_camera_: *anyopaque, x_by: f32, y_by: f32) void {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    target_camera.*.target.x += x_by;
    target_camera.*.target.y += y_by;
}

pub fn setCameraPosition(target_camera_: *anyopaque, x: f32, y: f32) void {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    target_camera.target.x, target_camera.target.y = calculateCameraTarget(target_camera_, x, y);
}

pub fn calculateCameraTarget(target_camera_: *anyopaque, x: f32, y: f32) struct { f32, f32 } {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    const center_x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
    const center_y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;
    const center = rl.getScreenToWorld2D(.{ .x = center_x, .y = center_y }, target_camera.*);

    const current = rl.getScreenToWorld2D(target_camera.offset, target_camera.*);
    const diff = rl.Vector2{
        .x = center.x - current.x,
        .y = center.y - current.y,
    };

    return .{ x - diff.x, y - diff.y };
}

pub fn setCameraPositionFromCameraInfo(camera_: *anyopaque, info: RenderMall.CameraInfo) void {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    camera.zoom = info.zoom;

    const current_world = rl.getScreenToWorld2D(camera.offset, camera.*);
    const info_world = rl.getScreenToWorld2D(.{ .x = info.offset.x, .y = info.offset.y }, camera.*);

    var x_diff = current_world.x - info_world.x;
    var y_diff = current_world.y - info_world.y;

    x_diff += info.target.x;
    y_diff += info.target.y;

    camera.target.x = x_diff;
    camera.target.y = y_diff;
}

pub fn centerCameraAt(target_camera_: *anyopaque, x: f32, y: f32) void {
    const target_camera = @as(*rl.Camera2D, @ptrCast(@alignCast(target_camera_)));
    target_camera.*.target.x = x - @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
    target_camera.*.target.y = y - @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;
}

pub fn beginScissorMode(x: f32, y: f32, width: f32, height: f32) void {
    rl.beginScissorMode(
        @intFromFloat(x),
        @intFromFloat(y),
        @intFromFloat(width),
        @intFromFloat(height),
    );
}

pub fn endScissorMode() void {
    rl.endScissorMode();
}

pub fn setCamera(camera_: *anyopaque, info: RenderMall.CameraInfo) void {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    camera.* = rl.Camera2D{
        .offset = .{ .x = info.offset.x, .y = info.offset.y },
        .target = .{ .x = info.target.x, .y = info.target.y },
        .rotation = info.rotation,
        .zoom = info.zoom,
    };
}

pub fn setClipboardText(text: [:0]const u8) void {
    rl.setClipboardText(text);
}

////////////////////////////////////////////////////////////////////////////////////////////// Info Callbacks

pub fn getScreenWidthHeight() struct { f32, f32 } {
    return .{
        @as(f32, @floatFromInt(rl.getScreenWidth())),
        @as(f32, @floatFromInt(rl.getScreenHeight())),
    };
}

pub fn cameraTargetsEqual(a_: *anyopaque, b_: *anyopaque) bool {
    const a = @as(*rl.Camera2D, @ptrCast(@alignCast(a_)));
    const b = @as(*rl.Camera2D, @ptrCast(@alignCast(b_)));

    return @round(a.target.x * 100) == @round(b.target.x * 100) and
        @round(a.target.y * 100) == @round(b.target.y * 100);
}

pub fn getViewFromCameraInfo(info: RenderMall.CameraInfo) RenderMall.ScreenView {
    const camera = rl.Camera2D{
        .target = .{ .x = info.target.x, .y = info.target.y },
        .offset = .{ .x = info.offset.x, .y = info.offset.y },
        .zoom = info.zoom,
        .rotation = info.rotation,
    };
    return getViewFromCameraInternal(camera);
}

pub fn getViewFromCamera(camera_: *anyopaque) RenderMall.ScreenView {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    return getViewFromCameraInternal(camera.*);
}

fn getViewFromCameraInternal(camera: rl.Camera2D) RenderMall.ScreenView {
    const start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
    const end = rl.getScreenToWorld2D(.{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())),
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())),
    }, camera);

    return RenderMall.ScreenView{
        .start = .{ .x = start.x, .y = start.y },
        .end = .{ .x = end.x, .y = end.y },
    };
}

pub fn getAbsoluteViewFromCamera() RenderMall.ScreenView {
    return RenderMall.ScreenView{
        .start = .{ .x = 0, .y = 0 },
        .end = .{
            .x = @as(f32, @floatFromInt(rl.getScreenHeight())),
            .y = @as(f32, @floatFromInt(rl.getScreenWidth())),
        },
    };
}

pub fn getScreenToWorld2D(camera_: *anyopaque, x: f32, y: f32) struct { f32, f32 } {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const result = rl.getScreenToWorld2D(.{ .x = x, .y = y }, camera.*);
    return .{ result.x, result.y };
}

pub fn getWorldToScreen2D(camera_: *anyopaque, x: f32, y: f32) struct { f32, f32 } {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    const result = rl.getWorldToScreen2D(.{ .x = x, .y = y }, camera.*);
    return .{ result.x, result.y };
}

pub fn getCameraZoom(camera_: *anyopaque) f32 {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    return camera.zoom;
}

pub fn getCameraInfo(camera_: *anyopaque) RenderMall.CameraInfo {
    const camera = @as(*rl.Camera2D, @ptrCast(@alignCast(camera_)));
    return RenderMall.CameraInfo{
        .offset = .{ .x = camera.offset.x, .y = camera.offset.y },
        .target = .{ .x = camera.target.x, .y = camera.target.y },
        .rotation = camera.rotation,
        .zoom = camera.zoom,
    };
}

////////////////////////////////////////////////////////////////////////////////////////////// Add Font

pub fn addRaylibFontToFontStore(rl_font: *rl.Font, name: []const u8, store: *FontStore) !void {
    rl.setTextureFilter(rl_font.texture, .trilinear);

    try store.addNewFont(rl_font, name, FONT_BASE_SIZE, @floatFromInt(rl_font.ascent));
    const f = store.map.getPtr(name) orelse unreachable;
    for (0..@intCast(rl_font.glyphCount)) |i| {
        try f.addGlyph(store.a, rl_font.glyphs[i].value, .{
            .width = rl_font.recs[i].width,
            .offsetX = @as(f32, @floatFromInt(rl_font.glyphs[i].offsetX)),
            .advanceX = @as(f32, @floatFromInt(rl_font.glyphs[i].advanceX)),
        });
    }
}
