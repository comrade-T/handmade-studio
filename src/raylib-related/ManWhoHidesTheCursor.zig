const std = @import("std");
const rl = @import("raylib");

//////////////////////////////////////////////////////////////////////////////////////////////

show_duration_ms: i64,
old_pos: rl.Vector2 = .{ .x = 0, .y = 0 },
old_timestamp: i64 = 0,

pub fn update(self: *@This()) void {
    const now = std.time.microTimestamp();
    const new_cursor_pos = rl.getMousePosition();
    if (self.old_pos.x != new_cursor_pos.x or self.old_pos.y != new_cursor_pos.y) {
        self.old_timestamp = now;
        self.old_pos = new_cursor_pos;
        rl.showCursor();
        return;
    }
    if (now - self.old_timestamp > self.show_duration_ms * 1_000) {
        if (rl.isMouseButtonDown(.left)) return;
        if (rl.isMouseButtonDown(.right)) return;
        if (rl.isMouseButtonDown(.middle)) return;
        rl.hideCursor();
    }
}
