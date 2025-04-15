const Canvas = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const WindowManager = @import("WindowManager");
const LangHub = WindowManager.LangHub;
const RenderMall = WindowManager.RenderMall;
const NotificationLine = WindowManager.NotificationLine;
const ConnectionManager = WindowManager.ConnectionManager;
const Window = WindowManager.Window;

//////////////////////////////////////////////////////////////////////////////////////////////

wm: *WindowManager,
last_edit: i64 = 0,
path: []const u8 = "",

pub fn new(a: Allocator, lang_hub: *LangHub, style_store: *RenderMall, nl: *NotificationLine) !Canvas {
    return Canvas{
        .wm = try WindowManager.create(a, lang_hub, style_store, nl),
    };
}

pub fn deinit(self: *@This()) void {
    self.wm.destroy();
}

pub fn loadFromFile(a: Allocator, path: []const u8, lang_hub: *LangHub, style_store: *RenderMall, nl: *NotificationLine) !Canvas {
    // TODO:
}

pub fn close(self: *@This()) void {
    // TODO:
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
