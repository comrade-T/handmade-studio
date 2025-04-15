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

const Canvas = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const WindowManager = @import("WindowManager");
pub const LangHub = WindowManager.LangHub;
pub const RenderMall = WindowManager.RenderMall;
pub const NotificationLine = @import("NotificationLine");

const ConnectionManager = WindowManager.ConnectionManager;
const Window = WindowManager.Window;
const WindowSourceHandler = WindowManager.WindowSourceHandler;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,

last_edit: i64 = 0,
path: []const u8 = "",

pub fn create(a: Allocator, lang_hub: *LangHub, mall: *RenderMall, nl: *NotificationLine) !*Canvas {
    const self = try a.create(@This());
    self.* = Canvas{ .wm = try WindowManager.create(a, lang_hub, mall, nl) };
    return self;
}

pub fn destroy(self: *@This(), a: Allocator) void {
    a.destroy(self);
    self.wm.destroy();
}

// pub fn close(self: *@This()) void {
//     // TODO:
// }

////////////////////////////////////////////////////////////////////////////////////////////// Load

pub fn loadFromFile(self: *@This(), path: []const u8) !Canvas {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = getParsedState(arena.allocator(), path);
    defer parsed.deinit();

    self.setCameraIfCanvasIsEmpty(parsed);
    try loadSession(arena.allocator, self.wm, parsed);
}

fn getParsedState(aa: Allocator, path: []const u8) !std.json.Parsed(WritableCanvasState) {
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("failed opening file '{s}', got err: {any} --> returning.\n", .{ path, err });
        return;
    };
    defer file.close();
    const stat = try file.stat();

    const buf = try aa.alloc(u8, stat.size);
    defer aa.free(buf);
    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    return try std.json.parseFromSlice(WritableCanvasState, aa, buf, .{
        .ignore_unknown_fields = true,
    });
}

fn setCameraIfCanvasIsEmpty(self: *@This(), parsed: WritableCanvasState) void {
    if (parsed.value.cameraInfo) |camera_info| blk: {
        var has_visible_windows = false;
        for (self.wm.wmap.keys()) |window| {
            if (!window.closed) {
                has_visible_windows = true;
                break;
            }
        }
        if (has_visible_windows) break :blk;
        self.wm.mall.rcb.setCamera(self.wm.mall.camera, camera_info);
        self.wm.mall.rcb.setCamera(self.wm.mall.target_camera, camera_info);
    }
}

fn loadSession(aa: Allocator, wm: *WindowManager, parsed: WritableCanvasState) !void {

    // If we load a session from a file, then load the same session again,
    // those carry the same winids, both for windows and connections.
    // Without adjusting `increment_winid_by`, we'll run into winid collisions,
    // which causes `connman.notifyTrackers()` to misbehave & cause leaks.

    var increment_winid_by: Window.ID = 0;
    const current_nano_timestamp = std.time.nanoTimestamp();
    for (parsed.value.windows) |window_state| {
        const winid = window_state.opts.id orelse continue;
        if (wm.connman.tracker_map.contains(winid)) {
            assert(current_nano_timestamp > winid);
            increment_winid_by = current_nano_timestamp - winid;
            break;
        }
    }

    var strid_to_handler_map = std.AutoArrayHashMapUnmanaged(i128, *WindowSourceHandler){};
    for (parsed.value.string_sources) |str_source| {
        const handler = try WindowSourceHandler.create(wm, .string, str_source.contents, wm.lang_hub);
        try wm.handlers.put(wm.a, handler, {});
        try strid_to_handler_map.put(aa, str_source.id, handler);
    }

    for (parsed.value.windows) |state| {
        var adjusted_opts = state.opts;
        if (adjusted_opts.id == null) continue;
        adjusted_opts.id.? += increment_winid_by;

        switch (state.source) {
            .file => |path| try wm.spawnWindow(.file, path, adjusted_opts, true, false),
            .string => |string_id| {
                const handler = strid_to_handler_map.get(string_id) orelse continue;
                try wm.spawnWindowFromHandler(handler, adjusted_opts, true);
            },
        }
    }

    for (parsed.value.connections) |conn| {
        var adjusted_connection = conn.*;
        adjusted_connection.start.win_id += increment_winid_by;
        adjusted_connection.end.win_id += increment_winid_by;

        assert(wm.connman.tracker_map.contains(adjusted_connection.start.win_id));
        assert(wm.connman.tracker_map.contains(adjusted_connection.end.win_id));
        try wm.connman.notifyTrackers(adjusted_connection);
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// Save

pub fn save(self: *@This()) !bool {
    if (self.path.len == 0) return false;
    try self.saveAs(self.path);
    return true;
}

pub fn saveAs(self: *@This(), path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const canvas_state = try produceWritableCanvasState(self.wm, path);

    const json_str = try std.json.stringifyAlloc(arena.allocator(), canvas_state, .{
        .whitespace = .indent_4,
    });
    try writeToFile(json_str, path);

    const msg = try std.fmt.allocPrint(arena.allocator(), "Session written to file '{s}' successfully", .{path});
    try self.wm.nl.setMessage(msg);
}

fn produceWritableCanvasState(aa: Allocator, wm: *WindowManager) !WritableCanvasState {
    var string_source_list = std.ArrayList(StringSource).init(aa);
    var window_to_id_map = std.AutoArrayHashMap(*Window, i128).init(aa);

    ///////////////////////////// handle string sources

    var last_id: i128 = std.math.maxInt(i128);
    for (wm.handlers.keys()) |handler| {
        if (handler.source.from == .file) continue;

        // only save handlers with visible windows
        var ignore_this_handler = true;
        for (handler.windows.keys()) |window| {
            if (!window.closed) {
                ignore_this_handler = false;
                break;
            }
        }
        if (ignore_this_handler) continue;

        var id = std.time.nanoTimestamp();
        while (true) {
            if (id != last_id) break;
            id = std.time.nanoTimestamp();
        }
        last_id = id;

        const contents = try handler.source.buf.ropeman.toString(aa, .lf);
        try string_source_list.append(StringSource{
            .id = id,
            .contents = contents,
        });

        for (handler.windows.keys()) |window| {
            try window_to_id_map.put(window, id);
        }
    }

    ///////////////////////////// handle windows

    var window_state_list = std.ArrayList(Window.WritableWindowState).init(aa);
    defer window_state_list.deinit();

    for (wm.wmap.keys()) |window| {
        if (window.closed) continue;
        const string_id: ?i128 = window_to_id_map.get(window) orelse null;
        const data = try window.produceWritableState(string_id);
        try window_state_list.append(data);
    }

    ///////////////////////////// handle connections

    var connections = std.ArrayListUnmanaged(*const ConnectionManager.Connection){};

    for (wm.connman.connections.keys()) |conn| {
        if (!conn.isVisible(wm)) continue;
        try connections.append(aa, conn);
    }

    ///////////////////////////// return

    return WritableCanvasState{
        .cameraInfo = wm.mall.icb.getCameraInfo(wm.mall.camera),
        .windows = window_state_list.items,
        .string_sources = string_source_list.items,
        .connections = connections.items,
    };
}

fn writeToFile(str: []const u8, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(str);
}

const StringSource = struct {
    id: i128,
    contents: []const u8,
};

const WritableCanvasState = struct {
    cameraInfo: ?RenderMall.CameraInfo = null,
    string_sources: []const StringSource,
    connections: []*const ConnectionManager.Connection,
    windows: []const Window.WritableWindowState,
};
