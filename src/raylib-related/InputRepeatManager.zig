const std = @import("std");
const rl = @import("raylib");

const _input_processor = @import("input_processor");
const Key = _input_processor.Key;
const InputFrame = _input_processor.InputFrame;
const MappingCouncil = _input_processor.MappingCouncil;

//////////////////////////////////////////////////////////////////////////////////////////////

frame: *InputFrame,
council: *MappingCouncil,

reached_trigger_delay: bool = false,
reached_repeat_rate: bool = false,

last_trigger: u128 = 0,
last_trigger_timestamp: i64 = 0,

trigger_delay: i64 = 150,
repeat_rate: i64 = 1000 / 62,

pub fn updateInputState(self: *@This()) !void {
    try self.updateKeyUps();
    try self.updateKeyDowns();
    try self.executeTriggerIfExists();
}

fn executeTriggerIfExists(self: *@This()) !void {
    if (self.council.produceFinalTrigger(self.frame)) |trigger| {
        const current_time = std.time.milliTimestamp();
        defer self.last_trigger = trigger;

        if (trigger != self.last_trigger) {
            self.reached_trigger_delay = false;
            self.reached_repeat_rate = false;
            self.last_trigger_timestamp = 0;
        }

        trigger: {
            if (self.reached_repeat_rate) {
                if (current_time - self.last_trigger_timestamp < self.repeat_rate) return;
                self.last_trigger_timestamp = current_time;
                break :trigger;
            }

            if (self.reached_trigger_delay) {
                if (current_time - self.last_trigger_timestamp < self.trigger_delay) return;
                self.reached_repeat_rate = true;
                self.last_trigger_timestamp = current_time;
                break :trigger;
            }

            if (current_time - self.last_trigger_timestamp < self.trigger_delay) return;
            self.reached_trigger_delay = true;
            self.last_trigger_timestamp = current_time;
        }

        try self.council.execute(self.frame);
    }
}

fn updateKeyUps(self: *@This()) !void {
    var i: usize = self.frame.downs.items.len;
    while (i > 0) {
        i -= 1;
        var code: c_int = @intCast(@intFromEnum(self.frame.downs.items[i].key));
        if (code < Key.mouse_code_offset) {
            const key: rl.KeyboardKey = @enumFromInt(code);
            if (rl.isKeyUp(key)) {
                try self.frame.keyUp(self.frame.downs.items[i].key);
                self.reached_trigger_delay = false;
                self.reached_repeat_rate = false;
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonUp(@enumFromInt(code))) {
                try self.frame.keyUp(self.frame.downs.items[i].key);
                self.reached_trigger_delay = false;
                self.reached_repeat_rate = false;
            }
        }
    }
}

fn updateKeyDowns(self: *@This()) !void {
    for (Key.values) |value| {
        var code: c_int = @intCast(value);
        if (code < Key.mouse_code_offset) {
            if (rl.isKeyDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try self.frame.keyDown(enum_value, .now);
            }
        } else {
            code -= Key.mouse_code_offset;
            if (rl.isMouseButtonDown(@enumFromInt(code))) {
                const enum_value: Key = @enumFromInt(value);
                try self.frame.keyDown(enum_value, .now);
            }
        }
    }
}
