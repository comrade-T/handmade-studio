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

const WindowManager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing_allocator = std.testing.allocator;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;
const assert = std.debug.assert;

const LangHub = @import("LangSuite").LangHub;
const StyleStore = @import("StyleStore");
const WindowSource = @import("WindowSource");
const Window = @import("Window");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

lang_hub: *LangHub,
style_store: *const StyleStore,

handlers: WindowSourceHandlerList,
fmap: FilePathToHandlerMap,
wmap: WindowToHandlerMap,

pub fn init(a: Allocator, lang_hub: *LangHub, style_store: *const StyleStore) !WindowManager {
    return WindowManager{
        .a = a,
        .lang_hub = lang_hub,
        .style_store = style_store,
        .handlers = WindowSourceHandlerList{},
        .fmap = FilePathToHandlerMap{},
        .wmap = WindowToHandlerMap{},
    };
}

pub fn deinit(self: *@This()) void {
    for (self.handlers.items) |*handler| handler.deinit(self.a);
    self.handlers.deinit(self.a);
    self.fmap.deinit(self.a);
    self.wmap.deinit(self.a);
}

pub fn spawnWindow(self: *@This(), from: WindowSource.InitFrom, source: []const u8, opts: Window.SpawnOptions) !void {
    try self.handlers.append(self.a, try WindowSourceHandler.init(self, from, source, self.lang_hub));
    var handler = &self.handlers.items[self.handlers.items.len - 1];
    const window = try handler.spawnWindow(self.a, opts, self.style_store);
    try self.wmap.put(self.a, window, handler);
    if (from == .file) try self.fmap.put(self.a, source, handler);
}

test spawnWindow {
    var lang_hub = try LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    const style_store = try StyleStore.createStyleStoreForTesting(testing_allocator);
    defer StyleStore.freeTestStyleStore(testing_allocator, style_store);

    {
        var wm = try WindowManager.init(testing_allocator, &lang_hub, style_store);
        defer wm.deinit();

        // spawn .string Window
        try wm.spawnWindow(.string, "hello world", .{});
        try eq(1, wm.handlers.items.len);
        try eq(1, wm.wmap.values().len);
        try eq(0, wm.fmap.values().len);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerList = std.ArrayListUnmanaged(WindowSourceHandler);
const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowList,

    const WindowList = std.ArrayListUnmanaged(*Window);

    fn init(wm: *WindowManager, from: WindowSource.InitFrom, source: []const u8, lang_hub: *LangHub) !WindowSourceHandler {
        return WindowSourceHandler{
            .source = try WindowSource.create(wm.a, from, source, lang_hub),
            .windows = WindowList{},
        };
    }

    fn deinit(self: *@This(), a: Allocator) void {
        for (self.windows.items) |window| window.destroy();
        self.windows.deinit(a);
        self.source.destroy();
    }

    fn spawnWindow(self: *@This(), a: Allocator, opts: Window.SpawnOptions, style_store: *const StyleStore) !*Window {
        try self.windows.append(a, try Window.create(a, self.source, opts, style_store));
        return self.windows.getLast();
    }
};
