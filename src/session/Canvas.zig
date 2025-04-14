const Canvas = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const WindowManager = @import("WindowManager");
const LangHub = WindowManager.LangHub;
const RenderMall = WindowManager.RenderMall;
const NotificationLine = WindowManager.NotificationLine;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,
last_edit: i64 = 0,

pub fn new(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall, nl: *NotificationLine) !Canvas {
    return Canvas{
        .wm = try WindowManager.create(a, lang_hub, style_store, nl),
    };
}

pub fn deinit(self: *@This()) void {
    self.wm.destroy();
}

pub fn loadFromFile(a: Allocator, path: []const u8, lang_hub: *LangHub, style_store: *RenderMall, nl: *NotificationLine) !Canvas {
    // TODO:
}

pub fn saveToFile(self: *@This()) !void {
    // TODO:
}

pub fn saveToFileAs(self: *@This(), path: []const u8) !void {
    // TODO:
}

pub fn close(self: *@This()) void {
    // TODO:
}
