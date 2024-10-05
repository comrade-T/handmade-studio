const WindowManager = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const DisplayCachePool = @import("DisplayCachePool.zig");
const sitter = @import("ts");
const Window = @import("Window.zig");
const Buffer = @import("neo_buffer").Buffer;

////////////////////////////////////////////////////////////////////////////////////////////// WindowManager

const WinList = ArrayList(*Window);
const PoolToWinListMap = AutoArrayHashMap(*DisplayCachePool, WinList);
const BufferToPoolMap = AutoArrayHashMap(*Buffer, PoolToWinListMap);

const PathToBufferMap = std.StringArrayHashMap(*Buffer);

a: Allocator,

render_callbacks: ?Window.RenderCallbacks,
assets_callbacks: ?DisplayCachePool.AssetsCallbacks,

buf_map: BufferToPoolMap,
path_to_buffer_map: PathToBufferMap,

pub fn init(a: Allocator, opts: InitOptions) !*WindowManager {
    const self = try a.create(@This());
    self.* = .{
        .a = a,

        .render_callbacks = opts.render_callbacks,
        .assets_callbacks = opts.assets_callbacks,

        .buf_map = BufferToPoolMap.init(a),
        .path_to_buffer_map = PathToBufferMap.init(a),
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    self.a.destroy(self);
}

///////////////////////////// Open File

pub fn openFileInNewWindow(self: *@This(), path: []const u8) !void {
    if (self.path_to_buffer_map.get(path) == null) {
        const buf = try Buffer.create(self.a, .file, path);
        self.path_to_buffer_map.put(path, buf);
        self.buf_map.put(buf, BufferToPoolMap.init(self.a));
    }

    const buf: *Buffer = self.path_to_buffer_map.get(path).?;
    const pool2wins: *PoolToWinListMap = self.buf_map.getPtr(buf).?;

    if (pool2wins.values().len == 0) {
        const dcp = try DisplayCachePool.init(self.a, buf, DisplayCachePool.__dummy_default_display, self.assets_callbacks);
        const win = try Window.create(self.a, .{
            .dcp = dcp,
            .render_callbacks = self.render_callbacks,
            .start_line = 0,
            .end_line = buf.roperoot.weights().bols - 1,
        });

        var win_list = WinList.init(self.a);
        try win_list.append(win);

        try pool2wins.put(dcp, win_list);
        return;
    }

    // TODO: there's no way to identify a DisplayCachePool
    // --> that's why I told you to make QuerySets you idiot
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const InitOptions = struct {
    langsuite: *sitter.LangSuite,
    render_callbacks: ?Window.RenderCallbacks = null,
    assets_callbacks: ?DisplayCachePool.AssetsCallbacks = null,
};

////////////////////////////////////////////////////////////////////////////////////////////// Helpers
