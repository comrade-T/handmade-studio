const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const _vw = @import("virtuous_window");
const Buffer = _vw.Buffer;
const Window = _vw.Window;
const FontData = _vw.FontData;
const FontDataIndexMap = _vw.FontDataIndexMap;

//////////////////////////////////////////////////////////////////////////////////////////////

const WindowIDTracker = struct {
    current_index: u32 = 0,
    fn next(self: *@This()) u32 {
        defer self.current_index += 1;
        return self.current_index;
    }
};

const WindowManager = struct {
    a: Allocator,
    window_id_tracker: WindowIDTracker,
    windows: std.AutoHashMap(u32, *Window),
    active_window: ?*Window,

    pub fn init(a: Allocator) !*WindowManager {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .window_id_tracker = WindowIDTracker{},
            .windows = std.AutoHashMap(u32, *Window).init(a),
        };
        return self;
    }

    pub fn deinit(self: *@This()) void {
        var window_iter = self.windows.valueIterator();
        while (window_iter.next()) |win| win.*.destroy();
        self.windows.deinit();
        self.a.destroy(self);
    }

    const default_spawn_options = Window.SpawnOptions{ .x = 400, .y = 100, .font_size = 40 };

    pub fn openFileInCurrentWindow(self: *@This(), file_path: []const u8) !void {
        const buf = try Buffer.create(self.a, .file, file_path);
        if (self.active_window == null) {
            const new_window = try self.spawnWindow(buf, default_spawn_options);
            self.active_window = new_window;
            return;
        }
        self.active_window.?.changeBuffer(buf);
    }

    pub fn openFileInNewWindow(self: *@This(), file_path: []const u8, opts: Window.SpawnOptions) !void {
        const buf = try Buffer.create(self.a, .file, file_path);
        const new_window = try self.spawnWindow(buf, opts);
        self.active_window = new_window;
    }

    fn spawnWindow(self: *@This(), buf: *Buffer, opts: Window.SpawnOptions) !*Window {
        const window = try Window.spawn(buf, opts);
        try self.windows.put(self.window_id_tracker.next(), window);
        return window;
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    try eq(1, 1);
}
