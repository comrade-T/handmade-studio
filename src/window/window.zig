const std = @import("std");

const _buf_mod = @import("neo_buffer");
pub const Buffer = _buf_mod.Buffer;
pub const sitter = _buf_mod.sitter;
const ts = sitter.b;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const eq = std.testing.expectEqual;
const eqStr = std.testing.expectEqualStrings;

const Window = @This();

//////////////////////////////////////////////////////////////////////////////////////////////

exa: Allocator,
buf: *Buffer,
contents: Contents = undefined,

const Contents = struct {
    window: *Window,
    lines: ArrayList(Line),
    line_colors: ArrayList(Colors),
    start_line: usize,
    end_line: usize,

    const Line = []u21;
    const Colors = []u32;

    fn createWithCapacity(win: *Window, start_line: usize, num_of_lines: usize) !Contents {
        const lines, const line_colors = try createLines(win, start_line, num_of_lines);
        return .{
            .window = win,
            .start_line = start_line,
            .end_line = start_line + num_of_lines -| 1,
            .lines = lines,
            .line_colors = line_colors,
        };
    }

    fn updateLines(self: *@This(), old_start_line: usize, old_end_line: usize, new_start_line: usize, new_end_line: usize) !void {
        var new_lines, var new_line_colors = try createLines(self.window, new_start_line, new_end_line -| new_start_line + 1);
        defer new_lines.deinit();
        defer new_line_colors.deinit();

        for (old_start_line..old_end_line + 1) |i| {
            self.window.exa.free(self.lines.items[i]);
            self.window.exa.free(self.line_colors.items[i]);
        }

        try self.lines.replaceRange(old_start_line, old_end_line -| old_start_line + 1, new_lines.items);
        try self.line_colors.replaceRange(old_start_line, old_end_line -| old_start_line + 1, new_line_colors.items);

        self.end_line = self.start_line + self.lines.items.len -| 1;
    }

    fn createLines(win: *Window, start_line: usize, num_of_lines: usize) !struct { ArrayList(Line), ArrayList(Colors) } {
        const end_line = start_line + num_of_lines -| 1;

        // add lines
        var lines = try ArrayList(Line).initCapacity(win.exa, num_of_lines);
        for (start_line..start_line + num_of_lines) |linenr| {
            const line = try win.buf.roperoot.getLineEx(win.exa, linenr);
            try lines.append(line);
        }

        // add default color
        var line_colors = try ArrayList(Colors).initCapacity(win.exa, num_of_lines);
        for (lines.items) |line| {
            const colors = try win.exa.alloc(u32, line.len);
            @memset(colors, 0xF5F5F5F5);
            try line_colors.append(colors);
        }

        // add TS highlights
        if (win.buf.langsuite) |langsuite| {
            const cursor = try ts.Query.Cursor.create();
            cursor.setPointRange(
                ts.Point{ .row = @intCast(start_line), .column = 0 },
                ts.Point{ .row = @intCast(end_line + 1), .column = 0 },
            );
            cursor.execute(langsuite.query.?, win.buf.tstree.?.getRootNode());
            defer cursor.destroy();

            while (true) {
                const result = langsuite.filter.?.nextMatchInLines(langsuite.query.?, cursor, Buffer.contentCallback, win.buf, start_line, end_line);
                switch (result) {
                    .match => |match| if (match.match == null) break,
                    .ignore => break,
                }
                const match = result.match;
                if (langsuite.highlight_map.?.get(match.cap_name)) |color| {
                    const node_start = match.cap_node.?.getStartPoint();
                    const node_end = match.cap_node.?.getEndPoint();
                    for (node_start.row..node_end.row + 1) |linenr| {
                        const line_index = linenr - start_line;
                        const start_col = if (linenr == node_start.row) node_start.column else 0;
                        const end_col = if (linenr == node_end.row) node_end.column else lines.items[line_index].len;
                        @memset(line_colors.items[line_index][start_col..end_col], color);
                    }
                }
            }
        }

        return .{ lines, line_colors };
    }

    fn destroy(self: *@This()) void {
        for (self.lines.items) |line| self.window.exa.free(line);
        for (self.line_colors.items) |lc| self.window.exa.free(lc);
        self.lines.deinit();
        self.line_colors.deinit();
    }
};
