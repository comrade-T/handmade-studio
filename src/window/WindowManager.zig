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

const LangSuite = @import("LangSuite");
const StyleStore = @import("StyleStore");
const WindowSource = @import("WindowSource");
const Window = @import("Window");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,
handlers: WindowSourceHandlerList,

pub fn init(a: Allocator) !WindowManager {
    return WindowManager{
        .a = a,
        .handlers = WindowSourceHandlerList{},
    };
}

pub fn deinit(self: *@This()) void {
    for (self.handlers.items) |*handler| handler.deinit(self.a);
    self.handlers.deinit(self.a);
}

// TODO: instead of having a filename as ID, we'd have a WindowSourceID type -> u32

pub fn spawn(self: *@This()) !void {
    _ = self;
}

//////////////////////////////////////////////////////////////////////////////////////////////

const WindowSourceHandlerList = std.ArrayListUnmanaged(WindowSourceHandler);
const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowList,

    const WindowList = std.ArrayListUnmanaged(*Window);

    fn init(a: Allocator, from: WindowSource.InitFrom, source: []const u8, lang_hub: *const LangSuite.LangHub) !WindowSourceHandler {
        return WindowSourceHandler{
            .source = try WindowSource.create(a, from, source, lang_hub),
            .windows = WindowList{},
        };
    }

    fn deinit(self: *@This(), a: Allocator) void {
        for (self.windows.items) |*window| window.destroy();
        self.windows.deinit(a);
        self.source.destroy();
    }

    fn spawnWindow(self: *@This(), a: Allocator, opts: Window.SpawnOptions, style_store: *const StyleStore) !void {
        const window = try Window.create(a, self.source, opts, style_store);
        self.windows.append(a, window);
    }
};
