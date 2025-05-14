// This file is part of Handmade Studio.
//
// Handmade Studio is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.
//
// Handmade Studio is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Handmade Studio. If not, see <http://www.gnu.org/licenses/>.

//////////////////////////////////////////////////////////////////////////////////////////////

const StrategicMap = @This();
const std = @import("std");
const Session = @import("Session.zig");
const RenderMall = Session.RenderMall;
const WindowManager = Session.WindowManager;
const progressAlphaChannel = RenderMall.ColorschemeStore.progressAlphaChannel;

//////////////////////////////////////////////////////////////////////////////////////////////

radius: f32 = 5,

left: f32 = 0,
right: f32 = 0,
top: f32 = 0,
bottom: f32 = 0,
width: f32 = 0,
height: f32 = 0,

padding: f32 = 75,
padding_min: f32 = 75,
padding_quant: f32 = 25,

progress: RenderMall.Progress = .{},

//////////////////////////////////////////////////////////////////////////////////////////////

pub fn isVisible(self: *const @This()) bool {
    return self.progress.value > 0;
}

pub fn show(self: *@This()) void {
    self.progress.mode = .in;
}

pub fn hide(self: *@This()) void {
    self.progress.mode = .out;
}

pub fn incrementCircleRadiusBy(self: *@This(), by: f32) void {
    self.radius += by;
}

pub fn render(self: *@This(), sess: *const Session) void {
    const wm = sess.getActiveCanvasWindowManager() orelse return;

    self.progress.update();
    self.updatePadding();

    const swidth, const sheight = sess.mall.icb.getScreenWidthHeight();
    sess.mall.rcb.drawRectangle(0, 0, swidth, sheight, progressAlphaChannel(0x000000aa, self.progress.value));

    self.updateBoundsInfo(wm);

    if (self.progress.value == 0) return;

    /////////////////////////////

    const width = swidth - (self.padding * 2);
    const height = sheight - (self.padding * 2);
    defer self.renderViewBounds(wm, width, height);

    for (wm.connman.connections.keys()) |conn| {
        if (!conn.isVisible()) continue;

        const start_x, const start_y = self.getConnPosition(conn.start, width, height);
        const end_x, const end_y = self.getConnPosition(conn.end, width, height);

        wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, 1, progressAlphaChannel(0xffffffff, self.progress.value));
    }

    /////////////////////////////

    for (wm.wmap.keys()) |win| {
        if (win.closed) continue;

        const xp = (win.getTargetX() - self.left) / self.width;
        const yp = (win.getTargetY() - self.top) / self.height;

        const wp = win.getWidth() / self.width;
        const hp = win.getHeight() / self.height;
        const ww = width * wp;
        const wh = height * hp;

        const x = self.padding + (width * xp) + (ww / 2);
        const y = self.padding + (height * yp) + (wh / 2);

        wm.mall.rcb.drawCircle(x, y, self.radius, progressAlphaChannel(win.defaults.color, self.progress.value));
    }
}

fn renderViewBounds(self: *@This(), wm: *const WindowManager, width: f32, height: f32) void {
    const rect = wm.mall.getScreenRect(wm.mall.camera);

    const xp = (rect.x - self.left) / self.width;
    const yp = (rect.y - self.top) / self.height;

    const wp = rect.width / self.width;
    const hp = rect.height / self.height;
    const w = width * wp;
    const h = height * hp;

    const x = self.padding + (width * xp);
    const y = self.padding + (height * yp);

    wm.mall.rcb.drawRectangleLines(x, y, w, h, 1, progressAlphaChannel(0xffffff88, self.progress.value));
}

fn getConnPosition(self: *const @This(), point: WindowManager.ConnectionManager.Connection.Point, width: f32, height: f32) struct { f32, f32 } {
    const win = point.win;

    const xp = (win.getTargetX() - self.left) / self.width;
    const yp = (win.getTargetY() - self.top) / self.height;
    const wx = self.padding + (width * xp);
    const wy = self.padding + (height * yp);

    const wp = win.getWidth() / self.width;
    const hp = win.getHeight() / self.height;
    const ww = width * wp;
    const wh = height * hp;

    return .{ wx + ww / 2, wy + wh / 2 };
}

fn updateBoundsInfo(self: *@This(), wm: *const WindowManager) void {
    self.left = std.math.floatMax(f32);
    self.right = -std.math.floatMax(f32);
    self.top = std.math.floatMax(f32);
    self.bottom = -std.math.floatMax(f32);

    for (wm.wmap.keys()) |win| {
        self.left = @min(self.left, win.getTargetX());
        self.right = @max(self.right, win.getTargetX() + win.getWidth());
        self.top = @min(self.top, win.getTargetY());
        self.bottom = @max(self.bottom, win.getTargetY() + win.getHeight());
    }

    self.width = self.right - self.left;
    self.height = self.bottom - self.top;
}

fn updatePadding(self: *@This()) void {
    self.padding = self.padding_min + (self.padding_quant * @as(f32, @floatFromInt(self.progress.value)) / 100);
}
