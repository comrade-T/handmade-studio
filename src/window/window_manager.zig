const std = @import("std");
const Window = @import("window");
const Buffer = @import("window").Buffer;

const sitter = @import("ts");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const WindowManager = @This();

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

const WindowList = ArrayList(*Window);
const BuffterToWindowListMap = std.AutoArrayHashMap(*Buffer, *WindowList);

a: Allocator,
buf_map: BuffterToWindowListMap,
active_window: ?*Window = null,

render_callbacks: ?Window.RenderCallbacks,
assets_callbacks: ?Window.AssetsCallbacks,

pub fn init(a: Allocator, opts: InitOptions) !*WindowManager {
    const self = try a.create(@This());
    self.* = .{
        .a = a,

        .buf_map = BuffterToWindowListMap.init(a),

        .render_callbacks = opts.render_callbacks,
        .assets_callbacks = opts.assets_callbacks,
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    for (self.buf_map.values()) |list| {
        for (list.items) |win| win.destroy();
        list.deinit();
        self.a.destroy(list);
    }
    for (self.buf_map.keys()) |buf| buf.destroy();
    self.buf_map.deinit();
    self.a.destroy(self);
}

///////////////////////////// Open File

fn openFileInNewWindow(self: *@This(), file_path: []const u8, may_dimensions: ?WindowDimensions) !void {
    const buf = try Buffer.create(self.a, .file, file_path);

    const dimensions = may_dimensions orelse WindowDimensions{};
    const win = try Window.create(self.a, buf, .{
        .render_callbacks = self.render_callbacks,
        .assets_callbacks = self.assets_callbacks,
        .x = dimensions.x,
        .y = dimensions.y,
        .bounds = dimensions.bounds,
    });

    if (self.buf_map.get(buf) == null) {
        const list = try self.a.create(WindowList);
        list.* = WindowList.init(self.a);
        try self.buf_map.put(buf, list);
    }
    assert(self.buf_map.get(buf) != null);
    if (self.buf_map.get(buf)) |list| try list.append(win);
}

test openFileInNewWindow {
    var ls = try sitter.LangSuite.create(testing_allocator, .zig);
    defer ls.destroy();

    var wm = try WindowManager.init(testing_allocator, .{ .langsuite = ls });
    defer wm.deinit();

    try wm.openFileInNewWindow("build.zig", null);
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const WindowDimensions = struct {
    x: f32 = 0,
    y: f32 = 0,
    bounds: ?Window.Bounds = null,
};

const InitOptions = struct {
    langsuite: *sitter.LangSuite,
    render_callbacks: ?Window.RenderCallbacks = null,
    assets_callbacks: ?Window.AssetsCallbacks = null,
};

////////////////////////////////////////////////////////////////////////////////////////////// Helpers
