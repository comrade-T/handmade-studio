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
    windows: std.AutoHashMap(u32, *Window),
    window_id_tracker: WindowIDTracker,

    pub fn create(a: Allocator) !*WindowManager {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .window_id_tracker = WindowIDTracker{},
            .windows = std.AutoHashMap(u32, *Window).init(a),
        };
        return self;
    }

    fn spawnWindow(self: *@This(), buf: *Buffer, opts: Window.SpawnOptions) !void {
        const window = try Window.spawn(buf, opts);
        try self.windows.put(self.window_id_tracker.next(), window);
    }
};

//////////////////////////////////////////////////////////////////////////////////////////////

test {
    try eq(2, 1);
}
