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
padding: Padding,
progress: RenderMall.Progress = .{},
cbounds: CanvasBounds = .{},
background: ?u32 = 0x000000aa,

const CanvasBounds = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    fn update(self: *@This(), wm: *const WindowManager) void {
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
};

const Padding = struct {
    left: PaddingSide,
    top: PaddingSide,
    right: PaddingSide,
    bottom: PaddingSide,

    fn update(self: *@This(), swidth: f32, sheight: f32, progress: u8) void {
        self.left.update(.left, swidth, sheight, progress);
        self.top.update(.top, swidth, sheight, progress);
        self.right.update(.right, swidth, sheight, progress);
        self.bottom.update(.bottom, swidth, sheight, progress);
    }
};

const PaddingSide = struct {
    min: f32 = 0,
    quant: f32,
    screen_percentage: f32 = 0,
    value: f32 = 0,

    fn update(self: *@This(), side: enum { left, top, right, bottom }, swidth: f32, sheight: f32, progress: u8) void {
        const push_by = switch (side) {
            .left, .right => swidth * self.screen_percentage,
            .top, .bottom => sheight * self.screen_percentage,
        };
        self.value = self.min + (self.quant * @as(f32, @floatFromInt(progress)) / 100) + push_by;
    }
};

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

pub fn render(self: *@This(), sess: *const Session, may_win: ?*WindowManager.Window) void {

    ///////////////////////////// update state

    const wm = sess.getActiveCanvasWindowManager() orelse return;

    const swidth, const sheight = sess.mall.icb.getScreenWidthHeight();
    self.progress.update();
    self.padding.update(swidth, sheight, self.progress.value);

    self.cbounds.update(wm);

    if (self.background) |bg| sess.mall.rcb.drawRectangle(0, 0, swidth, sheight, progressAlphaChannel(bg, self.progress.value));
    if (self.progress.value == 0) return;

    ///////////////////////////// render view bounds

    const width = swidth - (self.padding.left.value + self.padding.right.value);
    const height = sheight - (self.padding.top.value + self.padding.bottom.value);

    defer if (may_win) |win| {
        const win_center_x = win.getX() + win.getWidth() / 2;
        const win_center_y = win.getY() + win.getHeight() / 2;

        var info = wm.mall.icb.getCameraInfo(wm.mall.target_camera);
        info.target.x, info.target.y = wm.mall.icb.calculateCameraTarget(
            wm.mall.target_camera,
            win_center_x,
            win_center_y,
        );

        const view = wm.mall.icb.getViewFromCameraInfo(info);
        const rect = RenderMall.Rect{
            .x = view.start.x,
            .y = view.start.y,
            .width = view.end.x - view.start.x,
            .height = view.end.y - view.start.y,
        };

        self.renderViewBounds(wm, rect, width, height, 0xffffff88);
    } else self.renderViewBounds(wm, wm.mall.getScreenRect(wm.mall.camera), width, height, 0xffffff88);

    ///////////////////////////// render connections

    for (wm.connman.connections.keys()) |conn| {
        if (!conn.isVisible()) continue;

        const start_x, const start_y = self.getConnPosition(conn.start, width, height);
        const end_x, const end_y = self.getConnPosition(conn.end, width, height);

        wm.mall.rcb.drawLine(start_x, start_y, end_x, end_y, 1, progressAlphaChannel(0xffffffff, self.progress.value));
    }

    ///////////////////////////// render circles

    for (wm.wmap.keys()) |win| {
        if (win.closed) continue;

        const xp = (win.getTargetX() - self.cbounds.left) / self.cbounds.width;
        const yp = (win.getTargetY() - self.cbounds.top) / self.cbounds.height;

        const wp = win.getWidth() / self.cbounds.width;
        const hp = win.getHeight() / self.cbounds.height;
        const ww = width * wp;
        const wh = height * hp;

        const x = self.padding.left.value + (width * xp) + (ww / 2);
        const y = self.padding.top.value + (height * yp) + (wh / 2);

        wm.mall.rcb.drawCircle(x, y, self.radius, progressAlphaChannel(win.defaults.color, self.progress.value));
    }
}

fn renderViewBounds(self: *@This(), wm: *WindowManager, rect: RenderMall.Rect, width: f32, height: f32, color: u32) void {
    const xp = (rect.x - self.cbounds.left) / self.cbounds.width;
    const yp = (rect.y - self.cbounds.top) / self.cbounds.height;

    const wp = rect.width / self.cbounds.width;
    const hp = rect.height / self.cbounds.height;
    const w = width * wp;
    const h = height * hp;

    const x = self.padding.left.value + (width * xp);
    const y = self.padding.top.value + (height * yp);

    wm.mall.rcb.drawRectangleLines(x, y, w, h, 1, progressAlphaChannel(color, self.progress.value));
}

fn getConnPosition(self: *const @This(), point: WindowManager.ConnectionManager.Connection.Point, width: f32, height: f32) struct { f32, f32 } {
    const win = point.win;

    const xp = (win.getTargetX() - self.cbounds.left) / self.cbounds.width;
    const yp = (win.getTargetY() - self.cbounds.top) / self.cbounds.height;
    const wx = self.padding.left.value + (width * xp);
    const wy = self.padding.top.value + (height * yp);

    const wp = win.getWidth() / self.cbounds.width;
    const hp = win.getHeight() / self.cbounds.height;
    const ww = width * wp;
    const wh = height * hp;

    return .{ wx + ww / 2, wy + wh / 2 };
}
