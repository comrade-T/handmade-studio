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
const RenderMall = @import("RenderMall");
const WindowSource = @import("WindowSource");
const Window = @import("Window");

//////////////////////////////////////////////////////////////////////////////////////////////

a: Allocator,

lang_hub: *LangHub,
mall: *RenderMall,

active_window: ?*Window = null,

handlers: WindowSourceHandlerList,
fmap: FilePathToHandlerMap,
wmap: WindowToHandlerMap,

pub fn init(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall) !WindowManager {
    return WindowManager{
        .a = a,
        .lang_hub = lang_hub,
        .mall = style_store,
        .handlers = WindowSourceHandlerList{},
        .fmap = FilePathToHandlerMap{},
        .wmap = WindowToHandlerMap{},
    };
}

pub fn deinit(self: *@This()) void {
    for (self.handlers.items) |handler| handler.destroy(self.a);
    self.handlers.deinit(self.a);
    self.fmap.deinit(self.a);
    self.wmap.deinit(self.a);
}

////////////////////////////////////////////////////////////////////////////////////////////// Render

pub fn render(self: *@This()) void {
    for (self.wmap.keys()) |window| {
        const is_active = if (self.active_window) |active_window| active_window == window else false;
        window.render(is_active, self.mall);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Positioning

pub fn centerAt(self: *@This(), center_x: f32, center_y: f32) void {
    const active_window = self.active_window orelse return;
    active_window.centerAt(center_x, center_y);
}

pub fn moveBy(self: *@This(), x: f32, y: f32) void {
    const active_window = self.active_window orelse return;
    active_window.moveBy(x, y);
}

////////////////////////////////////////////////////////////////////////////////////////////// Insert & Delete

pub fn deleteRanges(self: *@This(), kind: WindowSource.DeleteRangesKind) !void {
    const active_window = self.active_window orelse return;

    var handler = self.wmap.get(active_window) orelse return;
    const result = try handler.source.deleteRanges(self.a, active_window.cursor_manager, kind) orelse return;
    defer self.a.free(result);

    for (handler.windows.items) |win| try win.processEditResult(result, self.mall);
}

pub fn insertChars(self: *@This(), chars: []const u8) !void {
    const active_window = self.active_window orelse return;

    var handler = self.wmap.get(active_window) orelse return;
    const result = try handler.source.insertChars(self.a, chars, active_window.cursor_manager) orelse return;
    defer self.a.free(result);

    for (handler.windows.items) |win| try win.processEditResult(result, self.mall);
}

////////////////////////////////////////////////////////////////////////////////////////////// Inputs

///////////////////////////// Normal Mode

pub fn deleteInSingleQuote(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.deleteRanges(.in_single_quote);
}

pub fn deleteInWord(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.deleteRanges(.in_word);
}

pub fn deleteInWORD(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.deleteRanges(.in_WORD);
}

///////////////////////////// Visual Mode

pub fn enterVisualMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.activateRangeMode();
}

pub fn exitVisualMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.activatePointMode();
}

pub fn delete(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.deleteRanges(.range);
    try exitVisualMode(ctx);
}

///////////////////////////// Insert Mode

pub fn backspace(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.deleteRanges(.backspace);
}

pub fn enterInsertMode_i(ctx: *anyopaque) !void {
    _ = ctx;
}

pub fn enterInsertMode_I(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
}

pub fn enterInsertMode_a(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.enterAFTERInsertMode(&window.ws.buf.ropeman);
}

pub fn enterInsertMode_A(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterInsertMode_a(ctx);
}

pub fn enterInsertMode_o(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterInsertMode_a(ctx);
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.insertChars("\n");
}

pub fn enterInsertMode_O(ctx: *anyopaque) !void {
    try moveCursorToBeginningOfLine(ctx);
    try enterInsertMode_i(ctx);
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.insertChars("\n");
    try moveCursorUp(ctx);
}

pub fn exitInsertMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    try window.ws.buf.ropeman.registerLastPendingToHistory();
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

pub fn debugPrintActiveWindowRope(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    try window.ws.buf.ropeman.debugPrint();
}

///////////////////////////// Movement

// $ 0 ^

pub fn moveCursorToBeginningOfLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveToBeginningOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToEndOfLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveToEndOfLine(&window.ws.buf.ropeman);
}

pub fn moveCursorToFirstNonSpaceCharacterOfLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveToFirstNonSpaceCharacterOfLine(&window.ws.buf.ropeman);
}

// hjkl

pub fn moveCursorUp(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveUp(1, &window.ws.buf.ropeman);
}

pub fn moveCursorDown(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveDown(1, &window.ws.buf.ropeman);
}

pub fn moveCursorLeft(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveLeft(1, &window.ws.buf.ropeman);
}

pub fn moveCursorRight(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.moveRight(1, &window.ws.buf.ropeman);
}

// Vim Word

pub fn moveCursorForwardWordStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardWordEnd(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsWordStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .word, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.forwardWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorForwardBIGWORDEnd(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.forwardWord(.end, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

pub fn moveCursorBackwardsBIGWORDStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const window = self.active_window orelse return;
    window.cursor_manager.backwardsWord(.start, .BIG_WORD, 1, &window.ws.buf.ropeman);
}

////////////////////////////////////////////////////////////////////////////////////////////// WindowSourceHandler

const WindowToHandlerMap = std.AutoArrayHashMapUnmanaged(*Window, *WindowSourceHandler);
const FilePathToHandlerMap = std.StringArrayHashMapUnmanaged(*WindowSourceHandler);

const WindowSourceHandlerList = std.ArrayListUnmanaged(*WindowSourceHandler);
const WindowSourceHandler = struct {
    source: *WindowSource,
    windows: WindowList,

    const WindowList = std.ArrayListUnmanaged(*Window);

    fn create(wm: *WindowManager, from: WindowSource.InitFrom, source: []const u8, lang_hub: *LangHub) !*WindowSourceHandler {
        const self = try wm.a.create(@This());
        self.* = WindowSourceHandler{
            .source = try WindowSource.create(wm.a, from, source, lang_hub),
            .windows = WindowList{},
        };
        return self;
    }

    fn destroy(self: *@This(), a: Allocator) void {
        for (self.windows.items) |window| window.destroy();
        self.windows.deinit(a);
        self.source.destroy();
        a.destroy(self);
    }

    fn spawnWindow(self: *@This(), a: Allocator, opts: Window.SpawnOptions, style_store: *const RenderMall) !*Window {
        const window = try Window.create(a, self.source, opts, style_store);
        try self.windows.append(a, window);

        // quick solution for limiting the cursor to the window limit
        window.cursor_manager.moveUp(1, &self.source.buf.ropeman);

        return window;
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Make closest window active

pub fn makeClosestWindowActive(self: *@This(), direction: WindowRelativeDirection) !void {
    const curr = self.active_window orelse return;
    var x_distance: f32 = std.math.floatMax(f32);
    var y_distance: f32 = std.math.floatMax(f32);
    var may_candidate: ?*Window = null;
    var candidate_status: enum { none, intersect, loose } = .none;

    for (self.wmap.keys()) |window| {
        if (window == curr) continue;
        switch (direction) {
            .right, .left => {
                const cond = if (direction == .right)
                    window.attr.pos.x > curr.attr.pos.x
                else
                    window.attr.pos.x < curr.attr.pos.x;

                if (window.verticalIntersect(curr)) candidate_status = .intersect;

                if (cond) {
                    if (window.verticalIntersect(curr) or may_candidate == null) {
                        const dx = @abs(window.attr.pos.x - curr.attr.pos.x);
                        if (dx < x_distance) {
                            may_candidate = window;
                            x_distance = dx;
                            if (candidate_status != .intersect) candidate_status = .loose;
                            continue;
                        }
                    }
                    if (candidate_status == .loose) handleLooseCandidate(window, curr, &x_distance, &y_distance, &may_candidate);
                }
            },
            .bottom, .top => {
                const cond = if (direction == .bottom)
                    window.attr.pos.y > curr.attr.pos.y
                else
                    window.attr.pos.y < curr.attr.pos.y;

                if (cond) {
                    if (window.horizontalIntersect(curr) or may_candidate == null) {
                        const dy = @abs(window.attr.pos.y - curr.attr.pos.y);
                        if (dy < y_distance) {
                            may_candidate = window;
                            y_distance = dy;
                            if (candidate_status != .intersect) candidate_status = .loose;
                            continue;
                        }
                    }
                    if (candidate_status == .loose) handleLooseCandidate(window, curr, &x_distance, &y_distance, &may_candidate);
                }
            },
        }
    }

    if (may_candidate) |candidate| self.active_window = candidate;
}

fn handleLooseCandidate(window: *Window, curr: *Window, x_distance: *f32, y_distance: *f32, may_candidate: *?*Window) void {
    const dx = @abs(window.attr.pos.x - curr.attr.pos.x);
    const dy = @abs(window.attr.pos.y - curr.attr.pos.y);

    if ((dx + dy) < (x_distance.* + y_distance.*)) {
        may_candidate.* = window;
        x_distance.* = dx;
        y_distance.* = dy;
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Spawn

pub fn spawnWindow(self: *@This(), from: WindowSource.InitFrom, source: []const u8, opts: Window.SpawnOptions, make_active: bool) !void {

    // if file path exists in fmap
    if (from == .file) {
        if (self.fmap.get(source)) |handler| {
            const window = try handler.spawnWindow(self.a, opts, self.mall);
            try self.wmap.put(self.a, window, handler);
            if (make_active or self.active_window == null) self.active_window = window;
            return;
        }
    }

    // spawn from scratch
    try self.handlers.append(self.a, try WindowSourceHandler.create(self, from, source, self.lang_hub));
    var handler = self.handlers.getLast();

    const window = try handler.spawnWindow(self.a, opts, self.mall);
    try self.wmap.put(self.a, window, handler);

    if (from == .file) try self.fmap.put(self.a, handler.source.path, handler);

    if (make_active or self.active_window == null) self.active_window = window;
}

test spawnWindow {
    var lang_hub = try LangHub.init(testing_allocator);
    defer lang_hub.deinit();

    const style_store = try RenderMall.createStyleStoreForTesting(testing_allocator);
    defer RenderMall.freeTestStyleStore(testing_allocator, style_store);

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

////////////////////////////////////////////////////////////////////////////////////////////// Auto Layout

pub const WindowRelativeDirection = enum { left, right, top, bottom };

pub fn spawnNewWindowRelativeToActiveWindow(
    self: *@This(),
    from: WindowSource.InitFrom,
    source: []const u8,
    opts: Window.SpawnOptions,
    direction: WindowRelativeDirection,
) !void {
    const prev = self.active_window orelse return;

    try self.spawnWindow(from, source, opts, true);
    const new = self.active_window orelse unreachable;

    var new_x: f32 = new.attr.target_pos.x;
    var new_y: f32 = new.attr.target_pos.y;
    switch (direction) {
        .right => {
            new_x = prev.attr.pos.x + prev.cached.width;
            new_y = prev.attr.pos.y;
        },
        .left => {
            new_x = prev.attr.pos.x - new.cached.width;
            new_y = prev.attr.pos.y;
        },
        .bottom => {
            new_x = prev.attr.pos.x;
            new_y = prev.attr.pos.y + prev.cached.height;
        },
        .top => {
            new_x = prev.attr.pos.x;
            new_y = prev.attr.pos.y - new.cached.height;
        },
    }
    new.setPosition(new_x, new_y);

    for (self.wmap.keys()) |window| {
        if (window == prev or window == new) continue;
        switch (direction) {
            .right => {
                if (window.attr.pos.x > prev.attr.pos.x and window.verticalIntersect(prev)) {
                    window.moveBy(new.cached.width, 0);
                }
            },
            .left => {
                if (window.attr.pos.x < prev.attr.pos.x and
                    window.verticalIntersect(prev))
                    window.moveBy(-new.cached.width, 0);
            },
            .bottom => {
                if (window.attr.pos.y > prev.attr.pos.y and
                    window.horizontalIntersect(prev))
                    window.moveBy(0, new.cached.height);
            },
            .top => {
                if (window.attr.pos.y < prev.attr.pos.y and
                    window.horizontalIntersect(prev))
                    window.moveBy(0, -new.cached.height);
            },
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Session

const session_file_path = ".handmade_studio/session.json";

pub fn loadSession(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    const file = std.fs.cwd().openFile(session_file_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("catched err: {any} --> returning.\n", .{err});
        return;
    };
    defer file.close();
    const stat = try file.stat();

    const buf = try self.a.alloc(u8, stat.size);
    defer self.a.free(buf);
    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    /////////////////////////////

    const parsed = try std.json.parseFromSlice([]const Window.WritableWindowState, self.a, buf, .{});
    defer parsed.deinit();

    for (parsed.value) |state| {
        try self.spawnWindow(state.from, state.source, state.opts, true);
    }
}

pub fn saveSession(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var list = std.ArrayList(Window.WritableWindowState).init(arena.allocator());
    for (self.wmap.keys()) |window| {
        const data = try window.produceWritableState(&arena);
        try list.append(data);
    }

    const str = try std.json.stringifyAlloc(arena.allocator(), list.items, .{
        .whitespace = .indent_4,
    });

    try writeToFile(str);
    std.debug.print("session written to file\n", .{});
}

fn writeToFile(str: []const u8) !void {
    var file = try std.fs.cwd().createFile(session_file_path, .{});
    defer file.close();
    try file.writeAll(str);
}
