const Window = @This();
const std = @import("std");
const ztracy = @import("ztracy");

pub const Buffer = @import("neo_buffer").Buffer;
const sitter = @import("ts");
const ts = sitter.b;
const neo_cell = @import("neo_cell.zig");
const ip = @import("input_processor");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const AutoArrayHashMap = std.AutoArrayHashMap;
const idc_if_it_leaks = std.heap.page_allocator;
const testing_allocator = std.testing.allocator;
const assert = std.debug.assert;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

////////////////////////////////////////////////////////////////////////////////////////////// Window

a: Allocator,
buf: *Buffer,

cursor: Cursor = .{},
// TODO: find a better name for this field.
is_in_AFTER_insert_mode: bool = false,

x: f32,
y: f32,
bounds: Bounds,
bounded: bool,

cached: CachedContents = undefined,
cache_strategy: CachedContents.CacheStrategy = .entire_buffer,
default_display: CachedContents.Display,

queries: std.StringArrayHashMap(*sitter.StoredQuery),

render_callbacks: ?RenderCallbacks,
assets_callbacks: ?AssetsCallbacks,

pub fn create(
    a: Allocator,
    buf: *Buffer,
    opts: SpawnOptions,
) !*Window {
    const self = try a.create(@This());
    self.* = .{
        .a = a,
        .buf = buf,

        .default_display = opts.default_display,
        .x = opts.x,
        .y = opts.y,
        .bounds = if (opts.bounds) |b| b else Bounds{},
        .bounded = if (opts.bounds) |_| true else false,

        .queries = std.StringArrayHashMap(*sitter.StoredQuery).init(a),

        .render_callbacks = opts.render_callbacks,
        .assets_callbacks = opts.assets_callbacks,
    };
    if (buf.tstree) |_| {
        if (!opts.disable_default_queries) try self.enableQuery(sitter.DEFAULT_QUERY_ID);
        for (opts.enabled_queries) |query_id| try self.enableQuery(query_id);
    }
    if (self.assets_callbacks) |cbs| self.default_display.setSize(' ', cbs);
    self.cached = try CachedContents.init(self.a, self, opts.cache_strategy);
    return self;
}

pub fn destroy(self: *@This()) void {
    self.queries.deinit();
    self.cached.deinit();
    self.a.destroy(self);
}

///////////////////////////// Render

pub fn render(self: *@This(), screen_view: ScreenView) void {
    const zone = ztracy.ZoneNC(@src(), "Window.render()", 0xFFAAFF);
    defer zone.End();

    // only temporary
    if (self.bounded) self.render_callbacks.?.drawRectangle(self.x, self.y, self.bounds.width, self.bounds.height, 0xFFFFFF22);

    self.setCursorRenderInfo(&self.cursor);
    if (self.bounded) self.adjustOffsetToCursorIfNeeded(&self.cursor);
    self.renderCursor(&self.cursor);

    self.renderCharacters(self.render_callbacks.?, self.assets_callbacks.?.font_manager, screen_view);
    self.renderVisualSelection();

    if (!self.bounded) self.adjustCameraToCursorIfNeeded(&self.cursor, screen_view);

    // TODO:
    if (self.bounded) self.renderBoundedWindowHandle();
}

///////////////////////////// Bounded Window Handle

fn renderBoundedWindowHandle(self: *@This()) void {
    const handle_width = 10;
    const handle_height = 40;
    const handle_x = self.x + self.bounds.width - handle_width;

    assert(self.cached.line_infos.items.len > 0);
    const first_lif = self.cached.line_infos.items[0];
    const last_lif = self.cached.line_infos.items[self.cached.line_infos.items.len - 1];
    const total_height = last_lif.y + last_lif.height - first_lif.y;

    const ratio = -(self.bounds.offset.y) / total_height;
    const handle_y = self.y - (ratio * handle_height) + (ratio * self.bounds.height);

    self.render_callbacks.?.drawRectangle(handle_x, handle_y, handle_width, handle_height, 0xFFFFFF88);
}

///////////////////////////// Adjust Offset

fn adjustOffsetToCursorIfNeeded(self: *@This(), cursor: *Cursor) void {
    const cursor_start_x = cursor.x + self.bounds.offset.x;
    const cursor_start_y = cursor.y + self.bounds.offset.y;
    const cursor_end_x = cursor_start_x + cursor.width;
    const cursor_end_y = cursor_start_y + cursor.height;

    const window_start_x = self.x;
    const window_start_y = self.y;
    const window_end_x = window_start_x + self.bounds.width;
    const window_end_y = window_start_y + self.bounds.height;

    if (cursor_end_x > window_end_x) self.bounds.offset.x -= cursor_end_x - window_end_x;
    if (cursor_end_y > window_end_y) self.bounds.offset.y -= cursor_end_y - window_end_y;

    if (cursor_start_x < window_start_x) self.bounds.offset.x += window_start_x - cursor_start_x;
    if (cursor_start_y < window_start_y) self.bounds.offset.y += window_start_y - cursor_start_y;
}

///////////////////////////// Adjust Camera

fn adjustCameraToCursorIfNeeded(self: *@This(), cursor: *Cursor, view: ScreenView) void {
    if (!cursor.just_moved) return;
    const cbs = self.render_callbacks orelse return;
    if (cursor.x + cursor.width > view.end.x) cbs.changeTargetXBy(cbs.smooth_cam, cursor.x + cursor.width - view.end.x);
    if (cursor.x < view.start.x) cbs.changeTargetXBy(cbs.smooth_cam, -(view.start.x - cursor.x));
    if (cursor.y + cursor.height > view.end.y) cbs.changeTargetYBy(cbs.smooth_cam, cursor.y + cursor.height - view.end.y);
    if (cursor.y < view.start.y) cbs.changeTargetYBy(cbs.smooth_cam, -(view.start.y - cursor.y));
    cursor.just_moved = false;
}

///////////////////////////// Render Visual Selection

fn renderVisualSelectionLine(self: *@This(), line_index: usize, start_col: usize, end_col: usize) void {
    assert(start_col <= end_col);

    const visual_selection_color = 0xFFFFFF44;
    const lif = self.cached.line_infos.items[line_index];
    const displays = self.cached.displays.items[line_index];

    if (displays.len == 0) {
        self.render_callbacks.?.drawRectangle(lif.x, lif.y, lif.width, lif.height, visual_selection_color);
        return;
    }

    const x = displays[start_col].position.x;
    const y = lif.y;
    const width = displays[end_col].position.x + displays[end_col].size.width - displays[start_col].position.x;
    const height = lif.height;

    self.render_callbacks.?.drawRectangle(x, y, width, height, visual_selection_color);
}

fn renderVisualSelection(self: *@This()) void {
    const start, const end = self.cursor.getVisualSelectionRange() orelse return;
    if (start.line == end.line) {
        self.renderVisualSelectionLine(start.line, start.col, end.col);
        return;
    }

    assert(end.line > start.line);
    assert(start.line >= self.cached.start_line);
    assert(end.line >= self.cached.start_line);
    const start_line_index = start.line - self.cached.start_line;
    const end_line_index = end.line - self.cached.start_line;

    self.renderVisualSelectionLine(start_line_index, start.col, self.cached.displays.items[start.line].len -| 1);
    if (end.line - start.line >= 2) {
        for (start_line_index + 1..end_line_index) |line_index| {
            self.renderVisualSelectionLine(line_index, 0, self.cached.displays.items[line_index].len -| 1);
        }
    }
    self.renderVisualSelectionLine(end_line_index, 0, end.col);
}

///////////////////////////// Render Cursor

fn setCursorRenderInfo(self: *@This(), cursor: *Cursor) void {
    const x, const y, const width, const height = self.getCursorRectangle(cursor);
    cursor.setRenderInfo(x, y, width, height);
}

fn renderCursor(self: *@This(), cursor: *Cursor) void {
    var x, var y, const width, const height = .{ cursor.x, cursor.y, cursor.width, cursor.height };
    if (self.bounded) {
        x += self.bounds.offset.x;
        y += self.bounds.offset.y;
    }
    const cursor_color = 0xF5F5F5F5;

    const view = self.render_callbacks.?.getScreenView(self.render_callbacks.?.screen_view);
    if (y + cursor.height > view.end.y) y = view.end.y - cursor.height;
    if (y < view.start.y) y = view.start.y;

    self.render_callbacks.?.drawRectangle(x, y, width, height, cursor_color);
}

fn getCursorRectangle(self: *@This(), cursor: *Cursor) struct { f32, f32, f32, f32 } {
    assert(cursor.line >= self.cached.start_line);
    const line_index = cursor.line - self.cached.start_line;
    const lif = self.cached.line_infos.items[line_index];
    const displays = self.cached.displays.items[line_index];

    if (displays.len == 0) return .{ lif.x, lif.y, self.default_display.size.width, self.default_display.size.height };

    if (cursor.col == displays.len) return .{ lif.x + lif.width, lif.y, self.default_display.size.width, self.default_display.size.height };

    assert(cursor.col < displays.len);
    const d = displays[cursor.col];
    return .{ d.position.x, d.position.y, d.size.width, d.size.height };
}

///////////////////////////// Render Characters

fn renderCharacters(self: *@This(), cbs: RenderCallbacks, font_manager: *anyopaque, view: ScreenView) void {
    if (self.bounded) return self.renderCharactersForBoundedWindow(cbs, font_manager, view);
    self.renderCharactersForUnboundWindow(cbs, font_manager, view);
}

fn renderCharactersForBoundedWindow(self: *@This(), cbs: RenderCallbacks, font_manager: *anyopaque, view: ScreenView) void {
    if (self.x > view.end.x) return;
    if (self.y > view.end.y) return;

    if (self.x + self.bounds.width < view.start.x) return;
    if (self.y + self.bounds.height < view.start.y) return;

    const bound_start_x = @max(view.start.x, self.x);
    const bound_end_x = @min(view.end.x, self.x + self.bounds.width);
    const bound_start_y = @max(view.start.y, self.y);
    const bound_end_y = @min(view.end.y, self.y + self.bounds.height);

    for (self.cached.line_infos.items, 0..) |lif, i| {
        const translated_lif_x = lif.x + self.bounds.offset.x;
        const translated_lif_y = lif.y + self.bounds.offset.y;

        if (translated_lif_y > bound_end_y) return;
        if (translated_lif_y + lif.height < bound_start_y) continue;

        if (translated_lif_x > bound_end_x) continue;
        if (translated_lif_x + lif.width < bound_start_x) continue;

        for (self.cached.displays.items[i], 0..) |d, j| {
            const translated_d_x = d.position.x + self.bounds.offset.x;
            const translated_d_y = d.position.y + self.bounds.offset.y;

            if (translated_d_x > bound_end_x) break;
            if (translated_d_x + d.size.width < bound_start_x) continue;

            switch (d.variant) {
                .char => |char| {
                    const code_point = self.cached.lines.items[i][j];
                    cbs.drawCodePoint(font_manager, code_point, char.font_face, char.font_size, char.color, translated_d_x, translated_d_y);
                },
                else => {},
            }
        }
    }
}

fn renderCharactersForUnboundWindow(self: *@This(), cbs: RenderCallbacks, font_manager: *anyopaque, view: ScreenView) void {
    for (self.cached.line_infos.items, 0..) |lif, i| {
        if (lif.y > view.end.y) return;
        if (lif.y + lif.height < view.start.y) continue;

        if (lif.x > view.end.x) continue;
        if (lif.x + lif.width < view.start.x) continue;

        for (self.cached.displays.items[i], 0..) |d, j| {
            if (d.position.x > view.end.x) break;
            if (d.position.x + d.size.width < view.start.x) continue;

            switch (d.variant) {
                .char => |char| {
                    const code_point = self.cached.lines.items[i][j];
                    cbs.drawCodePoint(font_manager, code_point, char.font_face, char.font_size, char.color, d.position.x, d.position.y);
                },
                else => {},
            }
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////// insertChars & deleteRange

pub fn insertChars(self: *@This(), cursor: *Cursor, chars: []const u8) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.insertChars()", 0xFF00AA);
    zone.Text(chars);
    defer zone.End();

    const new_pos, const may_ts_ranges = try self.buf.insertChars(chars, cursor.line, cursor.col);

    const cstart = cursor.line;
    const cend = new_pos.line;
    assert(cstart <= cend);

    try self.update(.{
        .lines = .{ .old_start = cstart, .old_end = cstart, .new_start = cstart, .new_end = cend },
        .displ = .{ .old_start = cstart, .old_end = cstart, .new_start = cstart, .new_end = cend },
        .infos = .{ .old_start = cstart, .old_end = cstart, .new_start = cstart, .new_end = cend },
        .ts = .{ .base_start = cstart, .base_end = cend, .ranges = may_ts_ranges },
        .sizes = .{ .start = cstart, .end = cend },
    });

    cursor.* = .{ .line = new_pos.line, .col = new_pos.col };
    cursor.just_moved = true;
}

test insertChars {
    {
        var tswin = try TSWin.init("", .{ .disable_default_queries = true, .enabled_queries = &.{"trimed_down_highlights"} });
        defer tswin.deinit();
        try eqStrU21Slice(&.{""}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "h");
        try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "ello");
        try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "\n");
        try eqStrU21Slice(&.{ "hello", "" }, tswin.win.cached.lines.items);
        try tswin.win.insertChars(&tswin.win.cursor, "\nworld");
        try eqStrU21Slice(&.{ "hello", "", "world" }, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("", .{ .disable_default_queries = true, .enabled_queries = &.{"trimed_down_highlights"} });
        defer tswin.deinit();
        {
            try tswin.win.insertChars(&tswin.win.cursor, "v");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "v", .default);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "ar");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, " not_false = true;");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try eqStrU21Slice(&.{"var not_false = true;"}, tswin.win.cached.lines.items);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "\n");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try eqStrU21Slice(&.{ "var not_false = true;", "" }, tswin.win.cached.lines.items);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "const eleven = 11;");
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " eleven = ", .default);
            try test_iter.next(1, "11", .{ .hl_group = "number" });
            try test_iter.next(1, ";", .default);
            try eqStrU21Slice(&.{ "var not_false = true;", "const eleven = 11;" }, tswin.win.cached.lines.items);
        }
    }
}

test "insert / delete crash check" {
    {
        const source =
            \\const ten = 10;
            \\fn dummy() void {
            \\}
            \\var x = 10;
            \\var y = 0;
        ;
        var tswin = try TSWin.init(source, .{ .disable_default_queries = true, .enabled_queries = &.{"trimed_down_highlights"} });
        defer tswin.deinit();
        {
            tswin.win.cursor = .{ .line = 2, .col = 1 };
            try tswin.win.backspace_internal(&tswin.win.cursor);
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "",
                "var x = 10;",
                "var y = 0;",
            }, tswin.win.cached.lines.items);
        }
    }
    {
        const source =
            \\const ten = 10;
            \\fn dummy() void {
            \\}
            \\pub var x = 0;
            \\pub var y = 0;
        ;
        var tswin = try TSWin.init(source, .{ .disable_default_queries = false, .enabled_queries = &.{""} });
        defer tswin.deinit();
        {
            tswin.win.cursor.set(4, 0);
            try Window.vimO(tswin.win);
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "pub var x = 0;",
                "pub var y = 0;",
                "",
            }, tswin.win.cached.lines.items);
        }
        {
            try tswin.win.insertChars(&tswin.win.cursor, "a");
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "pub var x = 0;",
                "pub var y = 0;",
                "a",
            }, tswin.win.cached.lines.items);
        }
        {
            try eq(6, tswin.win.bols());
            try eq(5, tswin.win.endLineNr());

            try tswin.win.backspace_internal(&tswin.win.cursor);
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "pub var x = 0;",
                "pub var y = 0;",
                "",
            }, tswin.win.cached.lines.items);
        }
    }
    {
        const source =
            \\const ten = 10;
            \\fn dummy() void {
            \\}
            \\pub var x = 0;
            \\pub var y = 0;
        ;
        var tswin = try TSWin.init(source, .{ .disable_default_queries = false, .enabled_queries = &.{""} });
        defer tswin.deinit();

        try Window.moveCursorDown(tswin.win);
        try Window.moveCursorDown(tswin.win);

        {
            try Window.vimO(tswin.win);
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "",
                "pub var x = 0;",
                "pub var y = 0;",
            }, tswin.win.cached.lines.items);
        }

        {
            try Window.backspace(tswin.win);
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "pub var x = 0;",
                "pub var y = 0;",
            }, tswin.win.cached.lines.items);
        }

        {
            try tswin.win.insertChars(&tswin.win.cursor, "\n");
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "",
                "pub var x = 0;",
                "pub var y = 0;",
            }, tswin.win.cached.lines.items);
        }

        {
            try tswin.win.insertChars(&tswin.win.cursor, "f");
            try eqStrU21Slice(&.{
                "const ten = 10;",
                "fn dummy() void {",
                "}",
                "f",
                "pub var x = 0;",
                "pub var y = 0;",
            }, tswin.win.cached.lines.items);

            {
                try Window.backspace(tswin.win);
                for (0..10) |_| {
                    try Window.backspace(tswin.win);
                    try tswin.win.insertChars(&tswin.win.cursor, "\n");
                }
                try Window.backspace(tswin.win);
                try eqStr(
                    \\4 5/65/61
                    \\  3 3/35/33
                    \\    2 2/34/32
                    \\      1 B| `const ten = 10;` |E
                    \\      1 B| `fn dummy() void {` |E
                    \\    1 B| `}`
                    \\  3 2/30/28
                    \\    1 `` |E
                    \\    2 2/29/28
                    \\      1 B| `pub var x = 0;` |E
                    \\      1 B| `pub var y = 0;`
                , try tswin.win.buf.roperoot.debugPrint());
            }
        }
    }
}

// fn debugPrintLines(self: *@This(), msg: []const u8) !void {
//     // _ = self;
//     // _ = msg;
//
//     std.debug.print("{s} ========================================\n", .{msg});
//     for (self.cached.lines.items) |line| {
//         var u8line = try idc_if_it_leaks.alloc(u8, line.len);
//         defer idc_if_it_leaks.free(u8line);
//         for (line, 0..) |char, i| {
//             u8line[i] = @intCast(char);
//         }
//         std.debug.print("'{s}'\n", .{u8line});
//     }
//
//     std.debug.print("~~~~~\n", .{});
//
//     std.debug.print("{s}\n", .{try self.buf.roperoot.debugPrint()});
// }

///////////////////////////// Update Cache

const UpdateCacheParameters = struct {
    const LinesParams = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };
    const TreeSitterParams = struct { base_start: usize, base_end: usize, ranges: ?[]const ts.Range };
    const DisplaySizesParams = struct { start: usize, end: usize };

    lines: LinesParams,
    displ: LinesParams,
    ts: TreeSitterParams,
    infos: LinesParams,
    sizes: DisplaySizesParams,
};

fn update(self: *@This(), p: UpdateCacheParameters) !void {
    const len_diff = try self.cached.updateObsoleteLines(p.lines.old_start, p.lines.old_end, p.lines.new_start, p.lines.new_end);
    self.cached.updateEndLine(len_diff);

    try self.cached.updateObsoleteDisplays(p.displ.old_start, p.displ.old_end, p.displ.new_start, p.displ.new_end);
    assert(self.cached.lines.items.len == self.cached.displays.items.len);

    try self.cached.updateObsoleteTreeSitterToDisplays(p.ts.base_start, p.ts.base_end, p.ts.ranges);
    try self.cached.updateObsoleteLineInfoList(p.infos.old_start, p.infos.old_end, p.infos.new_start, p.infos.new_end);
    self.cached.calculateDisplaySizes(p.sizes.start, p.sizes.end);
    self.cached.calculateAllDisplayPositions();
}

///////////////////////////// Delete

fn backspace_internal(self: *@This(), cursor: *Cursor) !void {
    if (cursor.line == 0 and cursor.col == 0) return;

    var start_line: usize = cursor.line;
    var start_col: usize = cursor.col -| 1;
    const end_line: usize = cursor.line;
    const end_col: usize = cursor.col;

    if (self.cursor.col == 0 and self.cursor.line > 0) {
        start_line = self.cursor.line - 1;
        assert(self.cursor.line - 1 >= self.cached.start_line);
        const line_index = self.cursor.line - 1 - self.cached.start_line;
        start_col = self.cached.lines.items[line_index].len;
    }

    try self.deleteRange(.{ start_line, start_col }, .{ end_line, end_col });

    cursor.set(start_line, start_col);
}

test backspace_internal {
    {
        var tswin = try TSWin.init("const not_false = true;", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();

        tswin.win.cursor.set(0, tswin.win.cached.lines.items[0].len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
        try tswin.win.backspace_internal(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.backspace_internal(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = tru", .default);
        }
        try tswin.win.backspace_internal(&tswin.win.cursor);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = t", .default);
        }

        tswin.win.cursor.set(0, 1);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "onst not_false = t", .default);
        }

        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        try eq(Cursor{ .line = 0, .col = 0 }, tswin.win.cursor);
        try tswin.win.backspace_internal(&tswin.win.cursor);
    }

    {
        var tswin = try TSWin.init("const one = 1;\nvar two = 2;\nconst not_false = true;", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " two = ", .default);
            try test_iter.next(1, "2", .{ .hl_group = "number" });
            try test_iter.next(1, ";", .default);
            try test_iter.next(2, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(2, " not_false = ", .default);
            try test_iter.next(2, "true", .{ .hl_group = "boolean" });
            try test_iter.next(2, ";", .default);
        }
        tswin.win.cursor.set(1, 0);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        try eq(2, tswin.win.cached.lines.items.len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " two = ", .default);
            try test_iter.next(0, "2", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " not_false = ", .default);
            try test_iter.next(1, "true", .{ .hl_group = "boolean" });
            try test_iter.next(1, ";", .default);
        }
        tswin.win.cursor.set(1, 0);
        try tswin.win.backspace_internal(&tswin.win.cursor);
        try eq(1, tswin.win.cached.lines.items.len);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " one = ", .default);
            try test_iter.next(0, "1", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "var", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " two = ", .default);
            try test_iter.next(0, "2", .{ .hl_group = "number" });
            try test_iter.next(0, ";", .default);
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
        for (0..100) |_| try tswin.win.backspace_internal(&tswin.win.cursor);
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
            try test_iter.next(0, ";", .default);
        }
    }
}

const Range = struct { usize, usize };
fn sortRanges(a: Range, b: Range) struct { Range, Range } {
    if (a[0] == b[0]) {
        if (a[1] < b[1]) return .{ a, b };
        return .{ b, a };
    }
    if (a[0] < b[0]) return .{ a, b };
    return .{ b, a };
}

test sortRanges {
    {
        const start, const end = sortRanges(.{ 0, 0 }, .{ 0, 1 });
        try eq(.{ 0, 0 }, start);
        try eq(.{ 0, 1 }, end);
    }
    {
        const start, const end = sortRanges(.{ 0, 2 }, .{ 0, 10 });
        try eq(.{ 0, 2 }, start);
        try eq(.{ 0, 10 }, end);
    }
    {
        const start, const end = sortRanges(.{ 1, 0 }, .{ 0, 10 });
        try eq(.{ 0, 10 }, start);
        try eq(.{ 1, 0 }, end);
    }
}

fn deleteRange(self: *@This(), a: struct { usize, usize }, b: struct { usize, usize }) !void {
    const zone = ztracy.ZoneNC(@src(), "Window.deleteRange()", 0x00000F);
    defer zone.End();

    const start, const end = sortRanges(a, b);
    const may_ts_ranges = try self.buf.deleteRange(start, end);

    try self.update(.{
        .lines = .{ .old_start = start[0], .old_end = end[0], .new_start = start[0], .new_end = start[0] },
        .displ = .{ .old_start = start[0], .old_end = end[0], .new_start = start[0], .new_end = start[0] },
        .infos = .{ .old_start = start[0], .old_end = end[0], .new_start = start[0], .new_end = start[0] },
        .ts = .{ .base_start = start[0], .base_end = start[0], .ranges = may_ts_ranges },
        .sizes = .{ .start = start[0], .end = end[0] },
    });
}

test deleteRange {
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 4 }, .{ 0, 5 });
        try eqStrU21Slice(&.{ "hell", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 1 });
        try eqStrU21Slice(&.{ "ell", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 1, 0 }, .{ 0, 3 });
        try eqStrU21Slice(&.{ "ellworld", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 2 }, .{ 1, 3 });
        try eqStrU21Slice(&.{"elus"}, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 3 }, .{ 1, 2 });
        try eqStrU21Slice(&.{ "helrld", "venus" }, tswin.win.cached.lines.items);
    }
    {
        var tswin = try TSWin.init("hello\nworld\nvenus", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();
        try eqStrU21Slice(&.{ "hello", "world", "venus" }, tswin.win.cached.lines.items);
        try tswin.win.deleteRange(.{ 0, 3 }, .{ 2, 2 });
        try eqStrU21Slice(&.{"helnus"}, tswin.win.cached.lines.items);
    }

    {
        var tswin = try TSWin.init("xconst not_false = true", .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });
        defer tswin.deinit();
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "xconst not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 1 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = ", .default);
            try test_iter.next(0, "true", .{ .hl_group = "boolean" });
        }
        try tswin.win.deleteRange(.{ 0, 22 }, .{ 0, 21 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " not_false = tru", .default);
        }
        try tswin.win.deleteRange(.{ 0, 0 }, .{ 0, 2 });
        {
            var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
            try test_iter.next(0, "nst not_false = tru", .default);
        }
    }
}

pub fn disableDefaultQueries(self: *@This()) void {
    try self.disableQuery(sitter.DEFAULT_QUERY_ID);
}

pub fn disableQuery(self: *@This(), name: []const u8) !void {
    _ = self.queries.orderedRemove(name);
}

pub fn enableQuery(self: *@This(), name: []const u8) !void {
    assert(self.buf.langsuite.?.queries != null);
    const langsuite = self.buf.langsuite orelse return;
    const queries = langsuite.queries orelse return;
    const ptr = queries.get(name) orelse return;
    _ = try self.queries.getOrPutValue(name, ptr);
}

fn bols(self: *const @This()) u32 {
    return self.buf.roperoot.weights().bols;
}

fn endLineNr(self: *const @This()) u32 {
    return self.bols() -| 1;
}

////////////////////////////////////////////////////////////////////////////////////////////// CachedContents

const CachedContents = struct {
    const LineInfo = struct {
        width: f32 = 0,
        height: f32 = 0,
        x: f32 = 0,
        y: f32 = 0,
        linenr: usize = 0,
    };
    const Display = struct {
        const Size = struct {
            width: f32 = 0,
            height: f32 = 0,
        };
        const Position = struct {
            x: f32 = 0,
            y: f32 = 0,
        };
        const Char = struct {
            font_size: f32,
            font_face: []const u8,
            color: u32,
        };
        const Image = struct {
            path: []const u8,
        };

        size: Size = .{},
        position: Position = .{},
        variant: union(enum) {
            char: Char,
            image: Image,
        },

        fn setSize(self: *@This(), code_point: u21, cbs: AssetsCallbacks) void {
            switch (self.variant) {
                .char => |char| {
                    if (cbs.glyph_callback(cbs.font_manager, char.font_face, code_point)) |glyph| {
                        const scale_factor: f32 = char.font_size / @as(f32, @floatFromInt(glyph.base_size));
                        var width = if (glyph.advanceX != 0) @as(f32, @floatFromInt(glyph.advanceX)) else glyph.width + @as(f32, @floatFromInt(glyph.offsetX));
                        width = width * scale_factor;
                        self.size = Display.Size{ .width = width, .height = char.font_size };
                    }
                },
                .image => |image| {
                    if (cbs.image_callback(cbs.image_manager, image.path)) |size| {
                        self.size = Display.Size{ .width = size.width, .height = size.height };
                    }
                },
            }
        }
    };
    const CacheStrategy = union(enum) {
        const Section = struct { start_line: usize, end_line: usize };
        entire_buffer,
        section: Section,
    };

    a: Allocator,
    win: *const Window,

    lines: ArrayList([]u21) = undefined,
    displays: ArrayList([]Display) = undefined,
    line_infos: ArrayList(LineInfo) = undefined,

    start_line: usize = 0,
    end_line: usize = 0,

    const InitError = error{ OutOfMemory, LineOutOfBounds };
    // TODO:                                             list specific errors
    fn init(a: Allocator, win: *const Window, strategy: CacheStrategy) anyerror!@This() {
        var self = try CachedContents.init_bare_internal(a, win, strategy);

        self.lines = try createLines(self.a, win, self.start_line, self.end_line);
        assert(self.lines.items.len == self.end_line - self.start_line + 1);

        self.displays = try self.createDefaultDisplays(self.start_line, self.end_line);
        assert(self.lines.items.len == self.displays.items.len);

        try self.applyTreeSitterToDisplays(self.start_line, self.end_line);

        self.line_infos = try self.createLineInfoList(self.start_line, self.end_line);
        self.calculateDisplaySizes(self.start_line, self.end_line);
        self.calculateAllDisplayPositions();

        return self;
    }

    const InitBareInternalError = error{OutOfMemory};
    fn init_bare_internal(a: Allocator, win: *const Window, strategy: CacheStrategy) InitBareInternalError!@This() {
        var self = CachedContents{
            .win = win,
            .a = a,
        };
        const end_linenr = self.win.endLineNr();
        switch (strategy) {
            .entire_buffer => self.end_line = end_linenr,
            .section => |section| {
                assert(section.start_line <= section.end_line);
                assert(section.start_line <= end_linenr and section.end_line <= end_linenr);
                self.start_line = section.start_line;
                self.end_line = section.end_line;
            },
        }
        return self;
    }

    test init_bare_internal {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        {
            const cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .entire_buffer);
            try eq(0, cc.start_line);
            try eq(4, cc.end_line);
        }
        {
            const cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .{ .section = .{ .start_line = 0, .end_line = 2 } });
            try eq(0, cc.start_line);
            try eq(2, cc.end_line);
        }
        {
            const cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            try eq(2, cc.start_line);
            try eq(4, cc.end_line);
        }
    }

    fn deinit(self: *@This()) void {
        for (self.lines.items) |line| self.a.free(line);
        self.lines.deinit();
        for (self.displays.items) |displays| self.a.free(displays);
        self.displays.deinit();
        self.line_infos.deinit();
    }

    ///////////////////////////// Initial Creation

    const CreateLinesError = error{ OutOfMemory, LineOutOfBounds };
    fn createLines(a: Allocator, win: *const Window, start_line: usize, end_line: usize) CreateLinesError!ArrayList([]u21) {
        assert(start_line <= end_line);
        assert(start_line <= win.endLineNr() and end_line <= win.endLineNr());
        var lines = ArrayList([]u21).init(a);
        for (start_line..end_line + 1) |linenr| {
            const line = try win.buf.roperoot.getLineEx(a, linenr);
            try lines.append(line);
        }
        return lines;
    }

    test createLines {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        {
            const cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .entire_buffer);
            const lines = try createLines(idc_if_it_leaks, win, cc.start_line, cc.end_line);
            try eqStrU21Slice(&.{ "1", "22", "333", "4444", "55555" }, lines.items);
        }
        {
            const cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            const lines = try createLines(idc_if_it_leaks, win, cc.start_line, cc.end_line);
            try eqStrU21Slice(&.{ "333", "4444", "55555" }, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 0);
            try eqStrU21Slice(&.{"1"}, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 0, 1);
            try eqStrU21Slice(&.{ "1", "22" }, lines.items);
        }
        {
            const lines = try createLines(idc_if_it_leaks, win, 1, 2);
            try eqStrU21Slice(&.{ "22", "333" }, lines.items);
        }
    }

    const CreateDefaultDisplaysError = error{OutOfMemory};
    fn createDefaultDisplays(self: *CachedContents, start_line: usize, end_line: usize) CreateDefaultDisplaysError!ArrayList([]Display) {
        assert(start_line >= self.start_line and end_line <= self.end_line);
        var list = ArrayList([]Display).init(self.a);
        for (start_line..end_line + 1) |linenr| {
            const line_index = linenr - self.start_line;
            const line = self.lines.items[line_index];
            const displays = try self.a.alloc(Display, line.len);
            @memset(displays, self.win.default_display);
            try list.append(displays);
        }
        return list;
    }

    test createDefaultDisplays {
        const win = try _createWinWithBuf("1\n22\n333\n4444\n55555");
        const dd = _default_display;

        // CachedContents contains lines & displays for entire buffer
        {
            var cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .entire_buffer);
            cc.lines = try createLines(idc_if_it_leaks, win, cc.start_line, cc.end_line);
            {
                const displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);
                try eq(5, displays.items.len);
                try eqDisplays(&.{dd}, displays.items[0]);
                try eqDisplays(&.{ dd, dd }, displays.items[1]);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[2]);
                try eqDisplays(&.{ dd, dd, dd, dd }, displays.items[3]);
                try eqDisplays(&.{ dd, dd, dd, dd, dd }, displays.items[4]);
            }
            {
                const displays = try cc.createDefaultDisplays(0, 0);
                try eq(1, displays.items.len);
                try eqDisplays(&.{dd}, displays.items[0]);
            }
            {
                const displays = try cc.createDefaultDisplays(1, 2);
                try eq(2, displays.items.len);
                try eqDisplays(&.{ dd, dd }, displays.items[0]);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[1]);
            }
        }

        // CachedContents contains lines & displays only for specific region
        {
            var cc = try CachedContents.init_bare_internal(idc_if_it_leaks, win, .{ .section = .{ .start_line = 2, .end_line = 4 } });
            cc.lines = try createLines(idc_if_it_leaks, win, cc.start_line, cc.end_line);
            {
                const displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);
                try eq(3, displays.items.len);
                try eqDisplays(&.{ dd, dd, dd }, displays.items[0]);
                try eqDisplays(&.{ dd, dd, dd, dd }, displays.items[1]);
                try eqDisplays(&.{ dd, dd, dd, dd, dd }, displays.items[2]);
            }
        }
    }

    // TODO:                                                                       list specific errors
    fn applyTreeSitterToDisplays(self: *@This(), start_line: usize, end_line: usize) anyerror!void {
        if (self.win.buf.tstree == null) return;

        for (self.win.queries.values()) |sq| {
            const query = sq.query;

            const cursor = try ts.Query.Cursor.create();
            defer cursor.destroy();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(start_line), .column = 0 },
                ts.Point{ .row = @intCast(end_line + 1), .column = 0 },
            );
            cursor.execute(query, self.win.buf.tstree.?.getRootNode());

            while (true) {
                const result = switch (sq.filter.nextMatchInLines(query, cursor, Buffer.contentCallback, self.win.buf, self.start_line, self.end_line)) {
                    .match => |result| result,
                    .stop => break,
                };

                var display = self.win.default_display;

                if (self.win.buf.langsuite.?.highlight_map) |hl_map| {
                    if (hl_map.get(result.cap_name)) |color| {
                        if (self.win.default_display.variant == .char) display.variant.char.color = color;
                    }
                }

                if (result.directives) |directives| {
                    for (directives) |d| {
                        switch (d) {
                            .font => |face| {
                                if (display.variant == .char) display.variant.char.font_face = face;
                            },
                            .size => |size| {
                                if (display.variant == .char) display.variant.char.font_size = size;
                            },
                            .img => |path| {
                                if (display.variant == .image) {
                                    display.variant.image.path = path;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }
                }

                const node_start = result.cap_node.getStartPoint();
                const node_end = result.cap_node.getEndPoint();
                for (node_start.row..node_end.row + 1) |linenr| {
                    if (linenr > self.end_line) continue;
                    assert(linenr >= self.start_line);
                    const line_index = linenr - self.start_line;
                    const start_col = if (linenr == node_start.row) node_start.column else 0;
                    const end_col = if (linenr == node_end.row) node_end.column else self.lines.items[line_index].len;
                    @memset(self.displays.items[line_index][start_col..end_col], display);
                }
            }
        }
    }

    test applyTreeSitterToDisplays {
        const source =
            \\const std = @import("std");
            \\const Allocator = std.mem.Allocator;
        ;
        var tswin = try TSWin.init(source, .{
            .disable_default_queries = true,
            .enabled_queries = &.{"trimed_down_highlights"},
        });

        defer tswin.deinit();

        {
            var cc = try CachedContents.init_bare_internal(testing_allocator, tswin.win, .entire_buffer);
            defer cc.deinit();
            cc.lines = try createLines(testing_allocator, tswin.win, cc.start_line, cc.end_line);
            cc.displays = try cc.createDefaultDisplays(cc.start_line, cc.end_line);

            try cc.applyTreeSitterToDisplays(cc.start_line, cc.end_line);
            var test_iter = DisplayChunkTester{ .cc = cc };

            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " std = ", .default);
            try test_iter.next(0, "@import", .{ .hl_group = "include" });
            try test_iter.next(0, "(\"std\");", .default);

            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " ", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, " = std.mem.", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, ";", .default);
        }

        try tswin.win.enableQuery("std_60_inter");
        {
            var cc = try CachedContents.init(testing_allocator, tswin.win, .entire_buffer);
            defer cc.deinit();
            var test_iter = DisplayChunkTester{ .cc = cc };

            try test_iter.next(0, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(0, " ", .default);
            try test_iter.next(0, "std", .{ .literal = .{ "Inter", 60, tswin.hl.get("variable").? } });
            try test_iter.next(0, " = ", .default);
            try test_iter.next(0, "@import", .{ .hl_group = "include" });
            try test_iter.next(0, "(\"std\");", .default);

            try test_iter.next(1, "const", .{ .hl_group = "type.qualifier" });
            try test_iter.next(1, " ", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, " = ", .default);
            try test_iter.next(1, "std", .{ .literal = .{ "Inter", 60, tswin.hl.get("variable").? } });
            try test_iter.next(1, ".mem.", .default);
            try test_iter.next(1, "Allocator", .{ .hl_group = "type" });
            try test_iter.next(1, ";", .default);
        }
    }

    ///////////////////////////// Update Obsolete

    const UpdateLinesError = error{ OutOfMemory, LineOutOfBounds };
    fn updateObsoleteLines(self: *@This(), old_start: usize, old_end: usize, new_start: usize, new_end: usize) UpdateLinesError!i128 {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.updateObsoleteLines()", 0xFF000F);
        defer zone.End();

        assert(new_start <= new_end);
        assert(new_start >= self.start_line);

        const old_len: i128 = @intCast(self.lines.items.len);
        var new_lines_list = try createLines(self.a, self.win, new_start, new_end);
        const new_lines = try new_lines_list.toOwnedSlice();
        defer self.a.free(new_lines);

        const replace_len = old_end - old_start + 1;
        for (0..replace_len) |i| {
            const index = new_start + i;
            self.a.free(self.lines.items[index]);
        }

        try self.lines.replaceRange(new_start, old_end - old_start + 1, new_lines);

        const len_diff: i128 = @as(i128, @intCast(self.lines.items.len)) - old_len;
        assert(self.end_line + len_diff >= self.start_line);
        return len_diff;
    }

    test updateObsoleteLines {
        {
            var tswin = try TSWin.init("", .{
                .disable_default_queries = true,
                .enabled_queries = &.{"trimed_down_highlights"},
            });
            defer tswin.deinit();
            try eqStrU21Slice(&.{""}, tswin.win.cached.lines.items);

            _ = try tswin.buf.insertChars("h", 0, 0);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("ello", 0, 1);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("\n", 0, 5);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                try eq(1, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{ "hello", "" }, tswin.win.cached.lines.items);
            }
        }
        {
            var tswin = try TSWin.init("", .{
                .disable_default_queries = true,
                .enabled_queries = &.{"trimed_down_highlights"},
            });
            defer tswin.deinit();
            _ = try tswin.buf.insertChars("h", 0, 0);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"h"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("ello", 0, 1);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                try eq(0, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{"hello"}, tswin.win.cached.lines.items);
            }
            _ = try tswin.buf.insertChars("\n", 0, 4);
            {
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                try eq(1, len_diff);
                tswin.win.cached.updateEndLine(len_diff);
                try eqStrU21Slice(&.{ "hell", "o" }, tswin.win.cached.lines.items);
            }
        }
    }

    fn updateEndLine(self: *@This(), len_diff: i128) void {
        const new_end_line = @as(i128, @intCast(self.end_line)) + len_diff;
        assert(new_end_line >= 0);
        self.end_line = @intCast(new_end_line);
    }

    fn updateObsoleteDisplays(self: *@This(), old_start: usize, old_end: usize, new_start: usize, new_end: usize) !void {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.updateObsoleteDisplays()", 0xAAAAA0);
        defer zone.End();

        var new_displays_list = try self.createDefaultDisplays(new_start, new_end);
        const new_displays = try new_displays_list.toOwnedSlice();
        defer self.a.free(new_displays);

        const replace_len = old_end - old_start + 1;
        for (0..replace_len) |i| {
            const index = new_start + i;
            self.a.free(self.displays.items[index]);
        }

        try self.displays.replaceRange(new_start, old_end - old_start + 1, new_displays);
    }

    test updateObsoleteDisplays {
        {
            var tswin = try TSWin.init("", .{
                .disable_default_queries = true,
                .enabled_queries = &.{"trimed_down_highlights"},
            });
            defer tswin.deinit();
            {
                _ = try tswin.buf.insertChars("h", 0, 0);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 0);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "h", .default);
            }
            {
                _ = try tswin.buf.insertChars("ello", 0, 1);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 0);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 0);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "hello", .default);
            }
            {
                _ = try tswin.buf.insertChars("\n", 0, 4);
                const len_diff = try tswin.win.cached.updateObsoleteLines(0, 0, 0, 1);
                tswin.win.cached.updateEndLine(len_diff);
                try tswin.win.cached.updateObsoleteDisplays(0, 0, 0, 1);
                var test_iter = DisplayChunkTester{ .cc = tswin.win.cached };
                try test_iter.next(0, "hell", .default);
                try test_iter.next(1, "o", .default);
            }
        }
    }

    fn updateObsoleteTreeSitterToDisplays(self: *@This(), base_start: usize, base_end: usize, ranges: ?[]const ts.Range) !void {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.updateObsoleteTreeSitterToDisplays()", 0x00AAFF);
        defer zone.End();

        var new_hl_start = base_start;
        var new_hl_end = base_end;
        if (ranges) |ts_ranges| {
            for (ts_ranges) |r| {
                new_hl_start = @min(new_hl_start, r.start_point.row);
                new_hl_end = @max(new_hl_end, r.end_point.row);
            }
        }

        zone.Value(@intCast(new_hl_end - new_hl_start));

        try self.applyTreeSitterToDisplays(new_hl_start, new_hl_end);
    }

    fn createLineInfoList(self: *@This(), start: usize, end: usize) !ArrayList(LineInfo) {
        var list = try ArrayList(LineInfo).initCapacity(self.a, self.lines.items.len);
        for (start..end + 1) |_| try list.append(LineInfo{});
        return list;
    }

    fn updateObsoleteLineInfoList(self: *@This(), old_start: usize, old_end: usize, new_start: usize, new_end: usize) !void {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.updateObsoleteLineInfoList()", 0xCCCCCC);
        defer zone.End();

        var new_list = try self.createLineInfoList(new_start, new_end);
        defer new_list.deinit();
        try self.line_infos.replaceRange(new_start, old_end - old_start + 1, new_list.items);
    }

    fn calculateDisplaySizes(self: *@This(), start: usize, end: usize) void {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.calculateDisplaySizes()", 0xABABAB);
        defer zone.End();

        const cbs = self.win.assets_callbacks orelse return;
        for (start..end + 1) |i| {
            const line_index = self.start_line + i;

            var line_width: f32 = 0;
            var line_height: f32 = 0;
            defer self.line_infos.items[line_index].width = line_width;
            defer self.line_infos.items[line_index].height = line_height;
            defer self.line_infos.items[line_index].linenr = i;

            if (self.displays.items[line_index].len == 0) {
                line_width += self.win.default_display.size.width;
                line_height = @max(line_height, self.win.default_display.size.height);
            }

            for (0..self.displays.items[line_index].len) |j| {
                const code_point = self.lines.items[line_index][j];
                self.displays.items[line_index][j].setSize(code_point, cbs);
                line_width += self.displays.items[line_index][j].size.width;
                line_height = @max(line_height, self.displays.items[line_index][j].size.height);
            }
        }
    }

    fn calculateAllDisplayPositions(self: *@This()) void {
        const zone = ztracy.ZoneNC(@src(), "CachedContents.calculateAllDisplayPositions()", 0xAAAA66);
        defer zone.End();

        var current_x = self.win.x;
        var current_y = self.win.y;

        for (self.displays.items, 0..) |displays, i| {
            var max_height: f32 = 0;
            self.line_infos.items[i].x = current_x;
            self.line_infos.items[i].y = current_y;
            defer current_x = self.win.x;
            defer current_y += max_height;
            if (displays.len == 0) max_height = self.win.default_display.size.height;
            for (displays, 0..) |d, j| {
                defer current_x += d.size.width;
                max_height = @max(max_height, d.size.height);
                self.displays.items[i][j].position.x = current_x;
                self.displays.items[i][j].position.y = current_y;
            }
        }
    }
};

////////////////////////////////////////////////////////////////////////////////////////////// Interactions

///////////////////////////// Toggle Window Bounds

pub fn toggleBounds(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.bounded = !self.bounded;
}

///////////////////////////// Insert Chars

pub const InsertCharsCb = struct {
    chars: []const u8,
    target: *Window,
    fn f(ctx: *anyopaque) !void {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        try self.target.insertChars(&self.target.cursor, self.chars);
    }
    pub fn init(allocator: Allocator, target: *Window, chars: []const u8) !ip.Callback {
        const self = try allocator.create(@This());
        self.* = .{ .chars = chars, .target = target };
        return ip.Callback{ .f = @This().f, .ctx = self, .quick = true };
    }
};

const Pair = struct { []const ip.Key, []const u8 };
const pairs = [_]Pair{
    .{ &.{.a}, "a" },             .{ &.{ .left_shift, .a }, "A" },             .{ &.{ .right_shift, .a }, "A" },
    .{ &.{.b}, "b" },             .{ &.{ .left_shift, .b }, "B" },             .{ &.{ .right_shift, .b }, "B" },
    .{ &.{.c}, "c" },             .{ &.{ .left_shift, .c }, "C" },             .{ &.{ .right_shift, .c }, "C" },
    .{ &.{.d}, "d" },             .{ &.{ .left_shift, .d }, "D" },             .{ &.{ .right_shift, .d }, "D" },
    .{ &.{.e}, "e" },             .{ &.{ .left_shift, .e }, "E" },             .{ &.{ .right_shift, .e }, "E" },
    .{ &.{.f}, "f" },             .{ &.{ .left_shift, .f }, "F" },             .{ &.{ .right_shift, .f }, "F" },
    .{ &.{.g}, "g" },             .{ &.{ .left_shift, .g }, "G" },             .{ &.{ .right_shift, .g }, "G" },
    .{ &.{.h}, "h" },             .{ &.{ .left_shift, .h }, "H" },             .{ &.{ .right_shift, .h }, "H" },
    .{ &.{.i}, "i" },             .{ &.{ .left_shift, .i }, "I" },             .{ &.{ .right_shift, .i }, "I" },
    .{ &.{.j}, "j" },             .{ &.{ .left_shift, .j }, "J" },             .{ &.{ .right_shift, .j }, "J" },
    .{ &.{.k}, "k" },             .{ &.{ .left_shift, .k }, "K" },             .{ &.{ .right_shift, .k }, "K" },
    .{ &.{.l}, "l" },             .{ &.{ .left_shift, .l }, "L" },             .{ &.{ .right_shift, .l }, "L" },
    .{ &.{.m}, "m" },             .{ &.{ .left_shift, .m }, "M" },             .{ &.{ .right_shift, .m }, "M" },
    .{ &.{.n}, "n" },             .{ &.{ .left_shift, .n }, "N" },             .{ &.{ .right_shift, .n }, "N" },
    .{ &.{.o}, "o" },             .{ &.{ .left_shift, .o }, "O" },             .{ &.{ .right_shift, .o }, "O" },
    .{ &.{.p}, "p" },             .{ &.{ .left_shift, .p }, "P" },             .{ &.{ .right_shift, .p }, "P" },
    .{ &.{.q}, "q" },             .{ &.{ .left_shift, .q }, "Q" },             .{ &.{ .right_shift, .q }, "Q" },
    .{ &.{.r}, "r" },             .{ &.{ .left_shift, .r }, "R" },             .{ &.{ .right_shift, .r }, "R" },
    .{ &.{.s}, "s" },             .{ &.{ .left_shift, .s }, "S" },             .{ &.{ .right_shift, .s }, "S" },
    .{ &.{.t}, "t" },             .{ &.{ .left_shift, .t }, "T" },             .{ &.{ .right_shift, .t }, "T" },
    .{ &.{.u}, "u" },             .{ &.{ .left_shift, .u }, "U" },             .{ &.{ .right_shift, .u }, "U" },
    .{ &.{.v}, "v" },             .{ &.{ .left_shift, .v }, "V" },             .{ &.{ .right_shift, .v }, "V" },
    .{ &.{.w}, "w" },             .{ &.{ .left_shift, .w }, "W" },             .{ &.{ .right_shift, .w }, "W" },
    .{ &.{.x}, "x" },             .{ &.{ .left_shift, .x }, "X" },             .{ &.{ .right_shift, .x }, "X" },
    .{ &.{.y}, "y" },             .{ &.{ .left_shift, .y }, "Y" },             .{ &.{ .right_shift, .y }, "Y" },
    .{ &.{.z}, "z" },             .{ &.{ .left_shift, .z }, "Z" },             .{ &.{ .right_shift, .z }, "Z" },
    .{ &.{.one}, "1" },           .{ &.{ .left_shift, .one }, "!" },           .{ &.{ .right_shift, .one }, "!" },
    .{ &.{.two}, "2" },           .{ &.{ .left_shift, .two }, "@" },           .{ &.{ .right_shift, .two }, "@" },
    .{ &.{.three}, "3" },         .{ &.{ .left_shift, .three }, "#" },         .{ &.{ .right_shift, .three }, "#" },
    .{ &.{.four}, "4" },          .{ &.{ .left_shift, .four }, "$" },          .{ &.{ .right_shift, .four }, "$" },
    .{ &.{.five}, "5" },          .{ &.{ .left_shift, .five }, "%" },          .{ &.{ .right_shift, .five }, "%" },
    .{ &.{.six}, "6" },           .{ &.{ .left_shift, .six }, "^" },           .{ &.{ .right_shift, .six }, "^" },
    .{ &.{.seven}, "7" },         .{ &.{ .left_shift, .seven }, "&" },         .{ &.{ .right_shift, .seven }, "&" },
    .{ &.{.eight}, "8" },         .{ &.{ .left_shift, .eight }, "*" },         .{ &.{ .right_shift, .eight }, "*" },
    .{ &.{.nine}, "9" },          .{ &.{ .left_shift, .nine }, "(" },          .{ &.{ .right_shift, .nine }, "(" },
    .{ &.{.zero}, "0" },          .{ &.{ .left_shift, .zero }, ")" },          .{ &.{ .right_shift, .zero }, ")" },
    .{ &.{.minus}, "-" },         .{ &.{ .left_shift, .minus }, "_" },         .{ &.{ .right_shift, .minus }, "_" },
    .{ &.{.equal}, "=" },         .{ &.{ .left_shift, .equal }, "+" },         .{ &.{ .right_shift, .equal }, "+" },
    .{ &.{.comma}, "," },         .{ &.{ .left_shift, .comma }, "<" },         .{ &.{ .right_shift, .comma }, "<" },
    .{ &.{.period}, "." },        .{ &.{ .left_shift, .period }, ">" },        .{ &.{ .right_shift, .period }, ">" },
    .{ &.{.slash}, "/" },         .{ &.{ .left_shift, .slash }, "?" },         .{ &.{ .right_shift, .slash }, "?" },
    .{ &.{.semicolon}, ";" },     .{ &.{ .left_shift, .semicolon }, ":" },     .{ &.{ .right_shift, .semicolon }, ":" },
    .{ &.{.apostrophe}, "'" },    .{ &.{ .left_shift, .apostrophe }, "\"" },   .{ &.{ .right_shift, .apostrophe }, "\"" },
    .{ &.{.backslash}, "\\" },    .{ &.{ .left_shift, .backslash }, "|" },     .{ &.{ .right_shift, .backslash }, "|" },
    .{ &.{.left_bracket}, "[" },  .{ &.{ .left_shift, .left_bracket }, "{" },  .{ &.{ .right_shift, .left_bracket }, "{" },
    .{ &.{.right_bracket}, "]" }, .{ &.{ .left_shift, .right_bracket }, "}" }, .{ &.{ .right_shift, .right_bracket }, "}" },
    .{ &.{.grave}, "`" },         .{ &.{ .left_shift, .grave }, "~" },         .{ &.{ .right_shift, .grave }, "~" },
    .{ &.{.space}, " " },         .{ &.{ .left_shift, .space }, " " },         .{ &.{ .right_shift, .space }, " " },
    .{ &.{.enter}, "\n" },        .{ &.{ .left_shift, .enter }, "\n" },        .{ &.{ .right_shift, .enter }, "\n" },
};

pub fn mapInsertModeCharacters(self: *@This(), council: *ip.MappingCouncil) !void {
    for (0..pairs.len) |i| {
        const keys, const chars = pairs[i];
        try council.map("insert", keys, try InsertCharsCb.init(council.arena.allocator(), self, chars));
    }
}

///////////////////////////// Backspace

pub fn backspace(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.backspace_internal(&self.cursor);
    self.cursor.just_moved = true;
}

///////////////////////////// Enter / Exit Insert Mode

pub fn enterAFTERInsertMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.is_in_AFTER_insert_mode = true;
    try moveCursorRight(self);
}

pub fn exitInsertMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.is_in_AFTER_insert_mode = false;
    try moveCursorLeft(self);
    self.cursor.cacheColumnNumber();
}

pub fn capitalA(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterAFTERInsertMode(ctx);
}

pub fn vimO(ctx: *anyopaque) !void {
    try moveCursorToEndOfLine(ctx);
    try enterAFTERInsertMode(ctx);
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    try self.insertChars(&self.cursor, "\n");
}

///////////////////////////// VisualMode

pub fn enterVisualMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.startVisualSelection();
}

pub fn exitVisualMode(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.endVisualSelection();
}

pub fn swapCursorWithVisualAnchor(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.swapPlacesWithVisualSelectionAnchor();
}

pub fn deleteVisualRange(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    if (self.cursor.getVisualSelectionRange()) |result| {
        const start, const end = result;

        var end_col = end.col;
        if (self.cached.displays.items[end.line].len > 0) end_col += 1;

        try self.deleteRange(.{ start.line, start.col }, .{ end.line, end_col });
        self.cursor.set(start.line, start.col);
        self.cursor.endVisualSelection();
    }
    self.cursor.just_moved = true;
}

///////////////////////////// Move cursor to mouse position

pub fn moveCursorToMouse(ctx: *anyopaque) !void {
    // const zone = ztracy.ZoneNC(@src(), "Window.moveCursorToMouse()", 0x5555FF);
    // defer zone.End();

    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const mouse_x, const mouse_y = self.render_callbacks.?.getMousePositionOnScreen(self.render_callbacks.?.camera);
    defer self.cursor.cacheColumnNumber();

    for (self.cached.line_infos.items, 0..) |lif, i| {
        var lif_start_y = lif.y;
        var lif_end_y = lif.y + lif.height;
        var lif_end_x = lif.x + lif.width;
        if (self.bounded) {
            lif_start_y += self.bounds.offset.y;
            lif_end_y += self.bounds.offset.y;
            lif_end_x += self.bounds.offset.x;
        }

        if (mouse_y < lif_start_y) continue;
        if (mouse_y > lif_end_y) continue;

        if (self.cached.displays.items[i].len == 0) {
            self.cursor.set(lif.linenr, 0);
            return;
        }

        if (mouse_x < lif.x) {
            self.cursor.set(lif.linenr, 0);
            return;
        }

        if ((mouse_x > lif_end_x) or (self.bounded and mouse_x > (self.x + self.bounds.width))) {
            assert(self.cached.displays.items[i].len > 0);
            self.cursor.set(lif.linenr, self.cached.displays.items[i].len - 1);
            return;
        }

        for (self.cached.displays.items[i], 0..) |d, j| {
            var dx = d.position.x;
            var dy = d.position.y;
            if (self.bounded) {
                dx += self.bounds.offset.x;
                dy += self.bounds.offset.y;
            }

            if (mouseInsideRectangle(
                .{ .x = mouse_x, .y = mouse_y },
                .{ .x = dx, .y = dy, .width = d.size.width, .height = d.size.height },
            )) {
                self.cursor.set(lif.linenr, j);
                return;
            }
        }
    }
}

const Point = struct { x: f32, y: f32 };
const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };

fn mouseInsideRectangle(mouse: Point, rec: Rectangle) bool {
    const rec_end_y = rec.y + rec.height;
    const rec_end_x = rec.x + rec.width;
    if (mouse.y < rec.y) return false;
    if (mouse.y > rec_end_y) return false;
    if (mouse.x < rec.x) return false;
    if (mouse.x > rec_end_x) return false;
    return true;
}

///////////////////////////// zz

pub fn zz(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const cursor = self.cursor;

    if (!self.bounded) {
        const cbs = self.render_callbacks orelse return;
        const view = self.getView();
        const view_height = self.getViewHeight();
        const view_mid_y = view.start.y + (view_height / 2);
        const cursor_mid_y = cursor.y + (cursor.height / 2);
        const diff = cursor_mid_y - view_mid_y;
        cbs.changeTargetYBy(cbs.smooth_cam, diff);
        return;
    }

    if (self.bounded) {
        const window_mid_y = self.y + (self.bounds.height / 2);
        const cursor_start_y = cursor.y + self.bounds.offset.y;
        const cursor_mid_y = cursor_start_y + (cursor.height / 2);

        const diff = cursor_mid_y - window_mid_y;
        self.bounds.offset.y -= diff;
    }
}

///////////////////////////// <C-d> <C-u> Half Page

fn getViewHeight(self: *@This()) f32 {
    const view = self.render_callbacks.?.getScreenView(self.render_callbacks.?.screen_view);
    return view.end.y - view.start.y;
}

fn getView(self: *@This()) ScreenView {
    return self.render_callbacks.?.getScreenView(self.render_callbacks.?.screen_view);
}

// up

pub fn moveCursorHalfPageUp(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const target_height = if (self.bounded) self.bounds.height / 2 else self.getViewHeight() / 2;

    const target_line = self.moveCursorUpHalfScreen(target_height);

    self.cursor.line = target_line;
    self.restrictCursorInView(&self.cursor);
    self.cursor.just_moved = true;
}

fn moveCursorUpHalfScreen(self: *@This(), target_height: f32) usize {
    var i: usize = self.cursor.line;
    var accu_height: f32 = 0;
    while (i >= 0) {
        accu_height += self.cached.line_infos.items[i].height;
        if (accu_height >= target_height) return i;
        i -|= 1;
    }
    return i;
}

// down

pub fn moveCursorHalfPageDown(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    const target_height = if (self.bounded) self.bounds.height / 2 else self.getViewHeight() / 2;

    const target_line = self.moveCursorDownHalfScreen(target_height);

    self.cursor.line = target_line;
    self.restrictCursorInView(&self.cursor);
    self.cursor.just_moved = true;
}

fn moveCursorDownHalfScreen(self: *@This(), target_height: f32) usize {
    var i: usize = self.cursor.line;
    var accu_height: f32 = 0;
    while (i < self.cached.line_infos.items.len) {
        accu_height += self.cached.line_infos.items[i].height;
        if (accu_height >= target_height) return i;
        i += 1;
    }
    return i;
}

///////////////////////////// Directional Cursor Movement

pub fn moveCursorToFirstLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.line = 0;
    self.restrictCursorInView(&self.cursor);
    self.cursor.just_moved = true;
}

pub fn moveCursorToLastLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.line = self.cached.lines.items.len - 1;
    self.restrictCursorInView(&self.cursor);
    self.cursor.just_moved = true;
}

pub fn moveCursorToBeginningOfLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.col = 0;
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn moveCursorToEndOfLine(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.col = self.cached.lines.items[self.cursor.line].len;
    self.restrictCursorInView(&self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn moveCursorToFirstNonBlankChar(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    defer self.cursor.cacheColumnNumber();
    defer self.cursor.just_moved = true;
    self.cursor.col = 0;
    if (self.cached.lines.items[self.cursor.line].len == 0) return;
    const first_char = self.cached.lines.items[self.cursor.line][0];
    if (!neo_cell.isSpace(first_char)) return;
    try vimForwardStart(self);
}

pub fn moveCursorLeft(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.col -|= 1;
    self.restrictCursorInView(&self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn moveCursorRight(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.col += 1;
    self.restrictCursorInView(&self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn moveCursorUp(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.line -|= 1;
    self.restrictCursorInView(&self.cursor);

    self.setCursorColumnToCachedColumnIfPossible(&self.cursor);
    self.cursor.just_moved = true;
}

pub fn moveCursorDown(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.cursor.line += 1;
    self.restrictCursorInView(&self.cursor);

    self.setCursorColumnToCachedColumnIfPossible(&self.cursor);
    self.cursor.just_moved = true;
}

fn setCursorColumnToCachedColumnIfPossible(self: *@This(), cursor: *Cursor) void {
    const line_index = cursor.line - self.cached.start_line;
    const line = self.cached.lines.items[line_index];
    if (cursor.cached_colnr < line.len -| 1) {
        cursor.set(cursor.line, cursor.cached_colnr);
    }
}

fn restrictCursorInView(self: *@This(), cursor: *Cursor) void {
    if (cursor.line < self.cached.start_line) cursor.line = self.cached.start_line;
    if (cursor.line > self.cached.end_line) cursor.line = self.cached.end_line;
    const current_line_index = cursor.line - self.cached.start_line;
    const current_line = self.cached.lines.items[current_line_index];
    if (current_line.len == 0) cursor.col = 0;

    const offset: usize = if (self.is_in_AFTER_insert_mode) 0 else 1;
    if (cursor.col > current_line.len -| offset) cursor.col = current_line.len -| 1;
}

///////////////////////////// Vim Cursor Movement

fn vimBackwards(self: *@This(), boundary_type: neo_cell.WordBoundaryType, cursor: *Cursor) void {
    const line, const col = neo_cell.backwardsByWord(boundary_type, self.cached.lines.items, cursor.line, cursor.col);
    cursor.set(line, col);
}

fn vimForward(self: *@This(), boundary_type: neo_cell.WordBoundaryType, cursor: *Cursor) void {
    const line, const col = neo_cell.forwardByWord(boundary_type, self.cached.lines.items, cursor.line, cursor.col);
    cursor.set(line, col);
}

pub fn vimForwardStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.vimForward(.start, &self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn vimForwardEnd(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.vimForward(.end, &self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

pub fn vimBackwardsStart(ctx: *anyopaque) !void {
    const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
    self.vimBackwards(.start, &self.cursor);
    self.cursor.cacheColumnNumber();
    self.cursor.just_moved = true;
}

////////////////////////////////////////////////////////////////////////////////////////////// Types

pub const SpawnOptions = struct {
    default_display: CachedContents.Display = _default_display,
    x: f32 = 0,
    y: f32 = 0,
    bounds: ?Bounds = null,
    disable_default_queries: bool = false,
    enabled_queries: []const []const u8 = &.{},
    cache_strategy: CachedContents.CacheStrategy = .entire_buffer,
    render_callbacks: ?RenderCallbacks = null,
    assets_callbacks: ?AssetsCallbacks = null,
};

pub const ScreenView = struct {
    start: struct { x: f32 = 0, y: f32 = 0 },
    end: struct { x: f32 = 0, y: f32 = 0 },
};

const RenderCallbacks = struct {
    drawCodePoint: *const fn (ctx: *anyopaque, code_point: u21, font_face: []const u8, font_size: f32, color: u32, x: f32, y: f32) void,
    drawRectangle: *const fn (x: f32, y: f32, width: f32, height: f32, color: u32) void,

    camera: *anyopaque,
    getMousePositionOnScreen: *const fn (camera: *anyopaque) struct { f32, f32 },

    smooth_cam: *anyopaque,
    setSmoothCamTarget: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    changeTargetXBy: *const fn (ctx: *anyopaque, by: f32) void,
    changeTargetYBy: *const fn (ctx: *anyopaque, by: f32) void,

    screen_view: *anyopaque,
    getScreenView: *const fn (ctx: *anyopaque) ScreenView,
};

const AssetsCallbacks = struct {
    font_manager: *anyopaque,
    glyph_callback: GetGlyphSizeCallback,
    image_manager: *anyopaque,
    image_callback: GetImageSizeCallback,
};

pub const Bounds = struct {
    width: f32 = 400,
    height: f32 = 400,
    padding: Padding = .{},
    offset: Offset = .{},

    const Padding = struct {
        top: f32 = 0,
        right: f32 = 0,
        bottom: f32 = 0,
        left: f32 = 0,
    };

    const Offset = struct {
        x: f32 = 0,
        y: f32 = 0,
    };
};

const Cursor = struct {
    line: usize = 0,
    col: usize = 0,

    /// in Vim, let's say your cursor is at column 5,
    /// move press 'k' move up a line,
    /// if that line has > 5 characters, your cursor will end up at column 5,
    /// if that line has < 5 characters, your cursor will end up at the last character of that line,
    /// if you press 'k' again, and the line has > 5 characters, your cursor will end up at column 5.
    /// and so on....
    /// until you actively move your cursor horizontally, then Vim will remember that column position.
    cached_colnr: usize = 0,

    /// if this is true, on `Window.render()`,
    /// it'll try to adjust the camera so that this cursor stays in view
    just_moved: bool = false,

    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    visual_selection_anchor: ?VisualSelectionAnchor = null,
    const VisualSelectionAnchor = struct { line: usize, col: usize };

    fn setRenderInfo(self: *@This(), x: f32, y: f32, width: f32, height: f32) void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;
    }

    fn swapPlacesWithVisualSelectionAnchor(self: *@This()) void {
        if (self.visual_selection_anchor) |anchor| {
            const new_anchor = VisualSelectionAnchor{ .line = self.line, .col = self.col };
            self.set(anchor.line, anchor.col);
            self.visual_selection_anchor = new_anchor;
        }
    }

    fn cacheColumnNumber(self: *@This()) void {
        self.cached_colnr = self.col;
    }

    fn hasVisualSelection(self: *@This()) bool {
        return !(self.visual_selection_anchor == null);
    }

    fn startVisualSelection(self: *@This()) void {
        self.visual_selection_anchor = .{ .line = self.line, .col = self.col };
    }

    fn endVisualSelection(self: *@This()) void {
        self.visual_selection_anchor = null;
    }

    fn getVisualSelectionRange(self: *@This()) ?struct { VisualSelectionAnchor, VisualSelectionAnchor } {
        const anchor = self.visual_selection_anchor orelse return null;
        const start, const end = sortRanges(.{ anchor.line, anchor.col }, .{ self.line, self.col });
        assert(end[0] >= start[0]);
        return .{ .{ .line = start[0], .col = start[1] }, .{ .line = end[0], .col = end[1] } };
    }

    fn set(self: *@This(), line: usize, col: usize) void {
        self.line = line;
        self.col = col;
    }
};

const Cell = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    variant: union(enum) {
        char: struct {
            code_point: u21,
            font_face: []const u8,
            font_size: f32,
            color: u32,
        },
        image: struct { path: []const u8 },
    },

    fn dbg(self: *const @This()) []u8 {
        switch (self.variant) {
            .char => |char| {
                var char_buf: [3]u8 = undefined;
                const char_len = std.unicode.utf8Encode(char.code_point, &char_buf) catch unreachable;
                const char_str = char_buf[0..char_len];
                return std.fmt.allocPrint(idc_if_it_leaks, "{d}:{d} {d}x{d} '{s}' '{s}' s{d} 0x{x}", .{
                    self.x,
                    self.y,
                    self.width,
                    self.height,
                    char_str,
                    char.font_face,
                    char.font_size,
                    char.color,
                }) catch unreachable;
            },
            .image => |image| {
                return std.fmt.allocPrint(idc_if_it_leaks, "{d}:{d} {d}x{d} '{s}'", .{
                    self.x,
                    self.y,
                    self.width,
                    self.height,
                    image.path,
                }) catch unreachable;
            },
        }
    }
};

const LineOfCells = struct {
    x: f32 = 0,
    y: f32 = 0,
    cursor_width: f32 = 0,
    cursor_height: f32 = 0,
    width: f32,
    height: f32,
    cells: []Cell,
};

const StoredQuery = struct {
    query: ts.Query,
    pattern: []const u8,
    id: []const u8,
};

pub const ImageInfo = struct {
    width: f32,
    height: f32,
};
pub const GetImageSizeCallback = *const fn (ctx: *anyopaque, path: []const u8) ?ImageInfo;

pub const Glyph = struct {
    advanceX: i32,
    offsetX: i32,
    width: f32,
    base_size: i32,
};
pub const GlyphMap = std.AutoArrayHashMap(u21, Glyph);
pub const GetGlyphSizeCallback = *const fn (ctx: *anyopaque, name: []const u8, char: u21) ?Glyph;

////////////////////////////////////////////////////////////////////////////////////////////// Test Helpers

fn eqStrU21Slice(expected: []const []const u8, got: [][]u21) !void {
    try eq(expected.len, got.len);
    for (0..expected.len) |i| {
        errdefer std.debug.print("comparison failed at index: {d}\n", .{i});
        try eqStrU21(expected[i], got[i]);
    }
}

fn eqStrU21(expected: []const u8, got: []u21) !void {
    var slice = try testing_allocator.alloc(u8, got.len);
    defer testing_allocator.free(slice);
    for (got, 0..) |cp, i| slice[i] = @intCast(cp);
    try eqStr(expected, slice);
}

const DisplayChunkTester = struct {
    i: usize = 0,
    current_line: usize = 0,
    cc: CachedContents,

    const ChunkVariant = union(enum) {
        default,
        hl_group: []const u8,
        literal: struct { []const u8, f32, u32 },
    };

    fn next(self: *@This(), linenr: usize, expected_str: []const u8, expected_variant: ChunkVariant) !void {
        if (linenr != self.current_line) {
            self.current_line = linenr;
            self.i = 0;
        }
        defer self.i += expected_str.len;

        try eqStrU21(expected_str, self.cc.lines.items[linenr][self.i .. self.i + expected_str.len]);

        var expected_display = self.cc.win.default_display;
        if (expected_display.variant == .char) {
            switch (expected_variant) {
                .hl_group => |hl_group| {
                    const color = self.cc.win.buf.langsuite.?.highlight_map.?.get(hl_group).?;
                    expected_display.variant.char.color = color;
                },
                .literal => |literal| {
                    expected_display.variant.char.font_face = literal[0];
                    expected_display.variant.char.font_size = literal[1];
                    expected_display.variant.char.color = literal[2];
                },
                else => {},
            }
        }

        const displays = self.cc.displays.items[linenr];
        for (displays[self.i .. self.i + expected_str.len], 0..) |d, i| {
            errdefer std.debug.print("display comparison failed at index [{d}] of sequence '{s}'\n", .{ i, expected_str });
            try eqDisplay(expected_display, d);
        }
    }
};

fn eqDisplay(expected: CachedContents.Display, got: CachedContents.Display) !void {
    switch (got.variant) {
        .char => |char| {
            errdefer std.debug.print("expected color 0x{x} got 0x{x}\n", .{ expected.variant.char.color, char.color });
            try eqStr(expected.variant.char.font_face, char.font_face);
            try eq(expected.variant.char.font_size, char.font_size);
            try eq(expected.variant.char.color, char.color);
        },
        .image => |image| {
            try eqStr(image.path, expected.variant.image.path);
        },
    }
}

fn eqDisplays(expected: []const CachedContents.Display, got: []CachedContents.Display) !void {
    try eq(expected.len, got.len);
    for (0..expected.len) |i| try eqDisplay(expected[i], got[i]);
}

const _default_display = CachedContents.Display{
    .variant = .{
        .char = .{
            .font_size = 40,
            .font_face = "Meslo",
            .color = 0xF5F5F5F5,
        },
    },
};

////////////////////////////////////////////////////////////////////////////////////////////// Test Setup Helpers

test {
    std.testing.refAllDecls(Window);
}

fn _createWinWithBuf(source: []const u8) !*Window {
    const buf = try Buffer.create(idc_if_it_leaks, .string, source);
    const win = try Window.create(idc_if_it_leaks, buf, .{});
    return win;
}

const MockManager = struct {
    a: Allocator,
    arena: std.heap.ArenaAllocator,
    maps: std.StringHashMap(GlyphMap),

    fn getGlyphInfo(ctx: *anyopaque, name: []const u8, char: u21) ?Glyph {
        const self = @as(*@This(), @ptrCast(@alignCast(ctx)));
        if (self.maps.get(name)) |map| if (map.get(char)) |glyph| return glyph;
        return null;
    }

    fn generateMonoGlyphMap(self: *@This(), size: i32, width_aspect_ratio: f32) GlyphMap {
        const height: f32 = @floatFromInt(size);
        const width: f32 = height * width_aspect_ratio;
        const glyph = Glyph{
            .width = width,
            .advanceX = 15,
            .offsetX = 4,
            .base_size = size,
        };
        var map = GlyphMap.init(self.arena.allocator());
        for (32..127) |i| map.put(@intCast(i), glyph) catch unreachable;
        return map;
    }

    fn getImageInfo(_: *anyopaque, path: []const u8) ?ImageInfo {
        if (eql(u8, path, "kekw.png")) return ImageInfo{ .width = 420, .height = 420 };
        return null;
    }

    fn create(a: Allocator) !*@This() {
        const self = try a.create(@This());
        self.* = .{
            .a = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .maps = std.StringHashMap(GlyphMap).init(self.arena.allocator()),
        };
        try self.maps.put("Meslo", self.generateMonoGlyphMap(40, 0.75));
        try self.maps.put("Inter", self.generateMonoGlyphMap(30, 0.5));
        return self;
    }

    fn assetsCallbacks(self: *@This()) AssetsCallbacks {
        return AssetsCallbacks{
            .font_manager = self,
            .glyph_callback = MockManager.getGlyphInfo,
            .image_manager = self,
            .image_callback = MockManager.getImageInfo,
        };
    }

    fn destroy(self: *@This()) void {
        self.arena.deinit();
        self.a.destroy(self);
    }
};

const TSWin = struct {
    langsuite: sitter.LangSuite = undefined,
    buf: *Buffer = undefined,
    win: *Window = undefined,
    hl: std.StringHashMap(u32) = undefined,
    mock_man: *MockManager = undefined,

    fn init(
        source: []const u8,
        spawn_opts: SpawnOptions,
    ) !@This() {
        var self = TSWin{
            .langsuite = try sitter.LangSuite.create(.zig),
            .buf = try Buffer.create(idc_if_it_leaks, .string, source),
        };
        try self.langsuite.initializeQueryMap(testing_allocator);
        try self.langsuite.initializeNightflyColorscheme(testing_allocator);
        self.hl = self.langsuite.highlight_map.?;
        try self.addCustomQueries();

        try self.buf.initiateTreeSitter(self.langsuite);

        self.mock_man = try MockManager.create(testing_allocator);
        var spawn_opts_clone = spawn_opts;
        spawn_opts_clone.assets_callbacks = self.mock_man.assetsCallbacks();

        self.win = try Window.create(testing_allocator, self.buf, spawn_opts);
        return self;
    }

    fn deinit(self: *@This()) void {
        self.langsuite.destroy();
        self.buf.destroy();
        self.win.destroy();
        self.mock_man.destroy();
    }

    fn addCustomQueries(self: *@This()) !void {
        try self.langsuite.addQuery(testing_allocator, "std_60_inter",
            \\ (
            \\   (IDENTIFIER) @variable
            \\   (#eq? @variable "std")
            \\   (#size! 60)
            \\   (#font! "Inter")
            \\ )
        );

        try self.langsuite.addQuery(testing_allocator, "trimed_down_highlights",
            \\ [
            \\   "const"
            \\   "var"
            \\ ] @type.qualifier
            \\
            \\ [
            \\  "true"
            \\  "false"
            \\ ] @boolean
            \\
            \\ (INTEGER) @number
            \\
            \\ ((BUILTINIDENTIFIER) @include
            \\ (#any-of? @include "@import" "@cImport"))
            \\
            \\ ;; assume TitleCase is a type
            \\ (
            \\   [
            \\     variable_type_function: (IDENTIFIER)
            \\     field_access: (IDENTIFIER)
            \\     parameter: (IDENTIFIER)
            \\   ] @type
            \\   (#match? @type "^[A-Z]([a-z]+[A-Za-z0-9]*)*$")
            \\ )
        );
    }
};
