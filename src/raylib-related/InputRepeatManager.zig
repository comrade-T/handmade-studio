const rl = @import("raylib");

const _input_processor = @import("input_processor");
const InputFrame = _input_processor.InputFrame;
const Key = _input_processor.Key;

//////////////////////////////////////////////////////////////////////////////////////////////

reached_trigger_delay: bool = false,
reached_repeat_rate: bool = false,

pub fn updateInputState(self: *@This(), frame: *InputFrame) !void {
    var i: usize = frame.downs.items.len;
    while (i > 0) {
        i -= 1;
        var code: c_int = @intCast(@intFromEnum(frame.downs.items[i].key));
        if (code < Key.mouse_code_offset) {
            const key: rl.KeyboardKey = @enumFromInt(code);
            if (rl.isKeyUp(key)) {
                try frame.keyUp(frame.downs.items[i].key);
                self.reached_trigger_delay = false;
                self.reached_repeat_rate = false;
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonUp(@enumFromInt(code))) {
                try frame.keyUp(frame.downs.items[i].key);
                self.reached_trigger_delay = false;
                self.reached_repeat_rate = false;
            }
        }
    }

    for (Key.values) |value| {
        var code: c_int = @intCast(value);
        if (code < Key.mouse_code_offset) {
            if (rl.isKeyDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try frame.keyDown(enum_value, .now);
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try frame.keyDown(enum_value, .now);
            }
        }
    }
}
