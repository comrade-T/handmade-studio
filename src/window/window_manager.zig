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

a: Allocator,

render_callbacks: ?Window.RenderCallbacks,
assets_callbacks: ?DisplayCachePool.AssetsCallbacks,

buf_map: BufferToPoolMap,

pub fn init(a: Allocator, opts: InitOptions) !*WindowManager {
    const self = try a.create(@This());
    self.* = .{
        .a = a,

        .render_callbacks = opts.render_callbacks,
        .assets_callbacks = opts.assets_callbacks,

        .buf_map = BufferToPoolMap.init(a),
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    self.a.destroy(self);
}

///////////////////////////// Open File

pub fn openFileInNewWindow(self: *@This(), path: []const u8) !void {
    // TODO:
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

const InitOptions = struct {
    langsuite: *sitter.LangSuite,
    render_callbacks: ?Window.RenderCallbacks = null,
    assets_callbacks: ?Window.AssetsCallbacks = null,
};

////////////////////////////////////////////////////////////////////////////////////////////// Helpers
