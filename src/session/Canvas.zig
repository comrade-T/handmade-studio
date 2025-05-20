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

const Session = @import("Session.zig");
const WindowManager = Session.WindowManager;
const RenderMall = Session.RenderMall;

const ConnectionManager = WindowManager.ConnectionManager;
const Window = WindowManager.Window;
const WindowSourceHandler = WindowManager.WindowSourceHandler;
const Arrowhead = WindowManager.ConnectionManager.ArrowheadManager.Arrowhead;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,
sess: *Session,
camera_info: RenderMall.CameraInfo = .{},

last_save: i64 = 0,
path: []const u8 = "",

marksman: MarksMan = .{},

pub fn create(sess: *Session) !*Canvas {
    const self = try sess.a.create(@This());
    const wm = try WindowManager.create(sess.a, sess.lang_hub, sess.mall);
    self.* = Canvas{ .sess = sess, .wm = wm };

    // temporary solution for LSP
    self.wm.post_file_open_callback_func = Session.postFileOpenCallback;
    self.wm.post_file_open_callback_ctx = sess;

    return self;
}

pub fn destroy(self: *@This()) void {
    if (self.path.len > 0) self.sess.a.free(self.path);
    self.wm.destroy();
    self.marksman.marks.deinit(self.sess.a);
    self.sess.a.destroy(self);
}

pub fn saveCameraInfo(self: *@This()) void {
    self.camera_info = self.wm.mall.icb.getCameraInfo(self.wm.mall.camera);
}

pub fn getName(self: *@This()) []const u8 {
    return if (self.path.len == 0) "[ UNNAMED CANVAS ]" else self.path;
}

pub fn hasUnsavedChanges(self: *@This()) bool {
    return self.path.len == 0 or (self.last_save != self.wm.hm.last_edit);
}

pub fn restoreCameraState(self: *const @This()) void {
    self.wm.mall.rcb.setCamera(self.wm.mall.camera, self.camera_info);
    self.wm.mall.rcb.setCamera(self.wm.mall.target_camera, self.camera_info);
}

////////////////////////////////////////////////////////////////////////////////////////////// Load

pub fn loadFromFile(self: *@This(), path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = try getParsedState(arena.allocator(), path) orelse return;
    defer parsed.deinit();

    self.setCameraIfCanvasIsEmpty(parsed.value);
    try self.loadSession(arena.allocator(), parsed.value);

    try self.setPath(path);
    self.setLastSaveTimestampToSameAsHistoryManager();
}

fn setLastSaveTimestampToSameAsHistoryManager(self: *@This()) void {
    // TODO: actually add a saved_at field to WritableCanvasState
    self.last_save = self.wm.hm.last_edit;
}

fn getParsedState(aa: Allocator, path: []const u8) !?std.json.Parsed(WritableCanvasState) {
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("failed opening file '{s}', got err: {any} --> returning.\n", .{ path, err });
        return null;
    };
    defer file.close();
    const stat = try file.stat();

    const buf = try aa.alloc(u8, stat.size);
    const read_size = try file.reader().read(buf);
    if (read_size != stat.size) return error.BufferUnderrun;

    return try std.json.parseFromSlice(WritableCanvasState, aa, buf, .{
        .ignore_unknown_fields = true,
    });
}

fn setCameraIfCanvasIsEmpty(self: *@This(), parsed: WritableCanvasState) void {
    if (parsed.cameraInfo) |camera_info| blk: {
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

fn loadSession(self: *@This(), aa: Allocator, parsed: WritableCanvasState) !void {
    const wm = self.wm;

    var strid_to_handler_map = std.AutoArrayHashMapUnmanaged(i128, *WindowSourceHandler){};
    for (parsed.string_sources) |str_source| {
        const handler = try WindowSourceHandler.create(
            wm,
            .{ .string = str_source.id },
            str_source.contents,
            wm.lang_hub,
        );
        try wm.handlers.put(wm.a, handler, {});
        try strid_to_handler_map.put(aa, str_source.id, handler);
    }

    var id_to_window_map = std.AutoArrayHashMapUnmanaged(Window.ID, *Window){};
    for (parsed.windows) |state| {
        switch (state.source) {
            .file => |path| _ = try wm.spawnWindow(.{ .file = path }, null, state.opts, true, false),
            .string => |string_id| {
                const handler = strid_to_handler_map.get(string_id) orelse continue;
                const window = try wm.spawnWindowFromHandler(handler, state.opts, true);
                try id_to_window_map.put(aa, window.id, window);
            },
        }
    }

    for (parsed.connections) |pconn| {
        const conn = ConnectionManager.Connection{
            .start = .{
                .anchor = pconn.start.anchor,
                .win = id_to_window_map.get(pconn.start.win_id) orelse unreachable,
            },
            .end = .{
                .anchor = pconn.end.anchor,
                .win = id_to_window_map.get(pconn.end.win_id) orelse unreachable,
            },
            .arrowhead_index = pconn.arrowhead_index,
            .hidden = pconn.hidden,
        };
        try wm.connman.addConnection(conn, false);
    }

    if (parsed.active_window_id) |id| blk: {
        for (wm.wmap.keys()) |win| {
            if (win.id == id) {
                wm.setActiveWindow(win, false);
                break :blk;
            }
        }
    }
    wm.wshm.reset();

    if (parsed.marks) |marks| {
        for (0..marks.keys.len) |i| {
            try self.marksman.marks.put(self.sess.a, marks.keys[i], marks.values[i]);
        }
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

    defer self.setLastSaveTimestampToSameAsHistoryManager();
    const canvas_state = try self.produceWritableCanvasState(arena.allocator());

    const json_str = try std.json.stringifyAlloc(arena.allocator(), canvas_state, .{
        .whitespace = .indent_4,
        .emit_null_optional_fields = false,
    });
    try writeToFile(json_str, path);

    const msg = try std.fmt.allocPrint(arena.allocator(), "Canvas written to file '{s}' successfully", .{path});
    try self.sess.nl.setMessage(msg);

    try self.setPath(path);
}

fn setPath(self: *@This(), new_path: []const u8) !void {
    if (std.mem.eql(u8, self.path, new_path)) return;
    if (self.path.len > 0) self.sess.a.free(self.path);
    self.path = try self.sess.a.dupe(u8, new_path);
}

fn produceWritableCanvasState(self: *@This(), aa: Allocator) !WritableCanvasState {
    const wm = self.wm;

    ///////////////////////////// handle string sources

    var string_source_list = std.ArrayListUnmanaged(StringSource){};

    for (wm.handlers.keys()) |handler| {
        if (handler.source.origin == .file) continue;

        // only save handlers with visible windows
        var ignore_this_handler = true;
        for (handler.windows.keys()) |window| {
            if (!window.closed) {
                ignore_this_handler = false;
                break;
            }
        }
        if (ignore_this_handler) continue;

        const contents = try handler.source.buf.ropeman.toString(aa, .lf);
        try string_source_list.append(aa, StringSource{
            .id = handler.source.origin.string,
            .contents = contents,
        });
    }

    ///////////////////////////// handle windows

    var window_state_list = std.ArrayListUnmanaged(Window.WritableWindowState){};

    for (wm.wmap.keys()) |window| {
        if (window.closed) continue;
        const data = try window.produceWritableState();
        try window_state_list.append(aa, data);
    }

    ///////////////////////////// handle connections

    var connections = std.ArrayListUnmanaged(ConnectionManager.PersistentConnection){};
    for (wm.connman.connections.keys()) |conn| {
        if (!conn.isVisible()) continue;
        try connections.append(aa, ConnectionManager.PersistentConnection.fromExistingConnection(conn));
    }

    ///////////////////////////// active_window_id

    const active_window = wm.active_window orelse null;
    const active_window_id: ?Window.ID = if (active_window) |aw| aw.id else null;

    ///////////////////////////// return

    return WritableCanvasState{
        .cameraInfo = wm.mall.icb.getCameraInfo(wm.mall.camera),
        .windows = window_state_list.items,
        .string_sources = string_source_list.items,
        .connections = connections.items,
        .active_window_id = active_window_id,
        .marks = WritableMarks{
            .keys = self.marksman.marks.keys(),
            .values = self.marksman.marks.values(),
        },
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
    string_sources: []const StringSource,
    connections: []const ConnectionManager.PersistentConnection,
    windows: []const Window.WritableWindowState,

    cameraInfo: ?RenderMall.CameraInfo = null,
    active_window_id: ?Window.ID = null,

    marks: ?WritableMarks = null,
};

////////////////////////////////////////////////////////////////////////////////////////////// Mark

const Mark = RenderMall.CameraInfo;
const WritableMarks = struct {
    keys: []const u32,
    values: []const Mark,
};
const MarksMan = struct {
    marks: std.AutoArrayHashMapUnmanaged(u32, Mark) = .{},
    before_jump_mark: Mark = .{},

    pub fn saveBeforeJumpMark(self: *@This(), sess: *Session) void {
        const info = sess.mall.icb.getCameraInfo(sess.mall.target_camera);
        self.before_jump_mark = info;
    }

    pub fn jumpToBeforeJumpMark(self: *@This(), sess: *Session) void {
        sess.mall.rcb.setCameraPositionFromCameraInfo(sess.mall.target_camera, self.before_jump_mark);
    }

    pub fn saveMark(self: *@This(), sess: *Session, keyboard_key: []const u8, key: u32) void {
        const info = sess.mall.icb.getCameraInfo(sess.mall.target_camera);
        self.marks.put(sess.a, key, info) catch unreachable;

        const msg = std.fmt.allocPrint(sess.a, "Saved current view to mark \"{s}\"", .{keyboard_key}) catch unreachable;
        defer sess.a.free(msg);
        sess.nl.setMessage(msg) catch unreachable;
    }

    pub fn jumpToMark(self: *@This(), sess: *Session, key: u32) void {
        const info = self.marks.get(key) orelse return;
        sess.mall.rcb.setCameraPositionFromCameraInfo(sess.mall.target_camera, info);
    }
};
