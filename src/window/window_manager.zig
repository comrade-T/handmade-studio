const std = @import("std");
const Window = @import("window");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const WindowManager = @This();

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

const WindowIDTracker = struct {
    current_index: u32 = 0,
    fn next(self: *@This()) u32 {
        defer self.current_index += 1;
        return self.current_index;
    }
};

a: Allocator,
window_id_tracker: WindowIDTracker,
windows: std.AutoArrayHashMap(u32, *Window),
active_window: ?*Window = null,

render_callbacks: ?Window.RenderCallbacks,
assets_callbacks: ?Window.AssetsCallbacks,

pub fn init(a: Allocator, opts: InitOptions) !*WindowManager {
    const self = try a.create(@This());
    self.* = .{
        .a = a,

        .window_id_tracker = WindowIDTracker{},
        .windows = std.AutoArrayHashMap(u32, *Window).init(a),

        .render_callbacks = opts.render_callbacks,
        .assets_callbacks = opts.assets_callbacks,
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    for (self.windows.values()) |win| win.destroy();
    self.windows.deinit();
    self.a.destroy(self);
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const InitOptions = struct {
    render_callbacks: ?Window.RenderCallbacks = null,
    assets_callbacks: ?Window.AssetsCallbacks = null,
};

//////////////////////////////////////////////////////////////////////////////////////////////

test init {
    var wm = try WindowManager.init(testing_allocator, .{});
    defer wm.deinit();
}
