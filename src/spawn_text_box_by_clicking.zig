const std = @import("std");
const rl = @import("raylib");

const kbs = @import("keyboard/state.zig");
const exp = @import("keyboard/experimental_mappings.zig");
const rope = @import("rope");

const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

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

    ///////////////////////////// Models

    const EditableTextBuffer = struct {
        external_allocator: Allocator,
        arena: std.heap.ArenaAllocator,
        a: Allocator,

        root: *const rope.Node,
        document: ArrayList(u8),

        x: i32,
        y: i32,

        fn spawn(external_allocator: Allocator, content: []const u8) !*@This() {
            var self = try external_allocator.create(@This());
            self.external_allocator = external_allocator;
            self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            self.a = self.arena.allocator();

            self.root = try rope.Node.fromString(self.a, content, true);
            self.document = try self.root.getDocument(self.a);

            self.x = rl.getMouseX();
            self.y = rl.getMouseY();

            return self;
        }

        fn destroy(self: *const @This()) void {
            self.arena.deinit();
            self.external_allocator.destroy(self);
        }
    };

    var buf_list = std.ArrayList(*EditableTextBuffer).init(gpa);
    defer {
        for (buf_list.items) |buf| buf.destroy();
        buf_list.deinit();
    }

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

        { // Spawn
            if (rl.isMouseButtonPressed(rl.MouseButton.mouse_button_left)) {
                const buf = try EditableTextBuffer.spawn(gpa, "Hello World!");
                try buf_list.append(buf);
            }
        }

        // View
        rl.beginDrawing();
        defer rl.endDrawing();
        {
            rl.clearBackground(rl.Color.blank);

            {
                for (buf_list.items) |buf| {
                    const content = @as([*:0]const u8, @ptrCast(buf.document.items));
                    rl.drawText(content, buf.x, buf.y, 30, rl.Color.ray_white);
                }
            }
        }
    }
}
