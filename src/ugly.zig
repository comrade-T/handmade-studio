const std = @import("std");
const rl = @import("raylib");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");

const eql = std.mem.eql;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {
    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Ugly");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// Controller

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    var kem = try kbs.KeyboardEventsManager.init(gpa);
    defer kem.deinit();

    // const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", 40, null);

    var trigger_map = try exp.createTriggerMap(gpa);
    defer trigger_map.deinit();

    var prefix_map = try exp.createPrefixMap(gpa);
    defer prefix_map.deinit();

    const TriggerCandidateComposer = kbs.GenericTriggerCandidateComposer(exp.TriggerMap, exp.PrefixMap);
    var composer = try TriggerCandidateComposer.init(gpa, &trigger_map, &prefix_map);
    defer composer.deinit();

    const TriggerPicker = kbs.GenericTriggerPicker(exp.TriggerMap);
    var picker = try TriggerPicker.init(gpa, &trigger_map);
    defer picker.deinit();

    ///////////////////////////// Model

    const Rectangle = struct {
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 100,
        height: i32 = 100,
        color: rl.Color = rl.Color.ray_white,

        fn collidesWithMouse(self: *const @This()) bool {
            const mouseX = rl.getMouseX();
            const mouseY = rl.getMouseY();
            const mouse_in_x_range = (self.x <= mouseX) and (mouseX <= self.x + self.width);
            const mouse_in_y_range = (self.y <= mouseY) and (mouseY <= self.y + self.height);
            if (mouse_in_x_range and mouse_in_y_range) return true;
            return false;
        }
    };
    var rectangles = std.ArrayList(Rectangle).init(gpa);
    defer rectangles.deinit();

    ///////////////////////////// Main Loop

    while (!rl.windowShouldClose()) {
        try kem.startHandlingInputs();
        {
            const input_steps = try kem.inputSteps();
            defer input_steps.deinit();

            for (input_steps.items) |step| {
                const insert_mode_active = true;
                var trigger: []const u8 = "";

                const candidate = try composer.getTriggerCandidate(step.old, step.new);
                if (!insert_mode_active) {
                    if (candidate) |c| trigger = c;
                }
                if (insert_mode_active) {
                    const may_final_trigger = try picker.getFinalTrigger(step.old, step.new, step.time, candidate);
                    if (may_final_trigger) |t| trigger = t;
                }

                if (!eql(u8, trigger, "")) {
                    defer picker.a.free(trigger);
                }
            }
        }
        try kem.finishHandlingInputs();

        // View
        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);

            if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_right) and rectangles.items.len > 0) {
                var i: usize = rectangles.items.len -| 1;
                while (true) {
                    if (rectangles.items[i].collidesWithMouse()) _ = rectangles.orderedRemove(i);
                    if (i == 0) break;
                    i -|= 1;
                }
            }

            if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_left)) {
                try rectangles.append(Rectangle{ .x = rl.getMouseX(), .y = rl.getMouseY() });
            }

            { // draw rectangles

                for (rectangles.items) |rec| {
                    if (rec.collidesWithMouse()) {
                        rl.drawRectangle(rec.x, rec.y, rec.width, rec.height, rl.Color.gray);
                    } else {
                        rl.drawRectangle(rec.x, rec.y, rec.width, rec.height, rec.color);
                    }
                }
            }
        }
    }
}
