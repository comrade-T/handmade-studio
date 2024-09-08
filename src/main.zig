const std = @import("std");
const rl = @import("raylib");
const ztracy = @import("ztracy");

const FileNavigator = @import("components/FileNavigator.zig");

const _neo_buffer = @import("neo_buffer");
const _vw = @import("virtuous_window");
const Window = _vw.Window;
const Buffer = _neo_buffer.Buffer;

const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const _input_processor = @import("input_processor");
const Key = _input_processor.Key;
const hash = _input_processor.hash;

//////////////////////////////////////////////////////////////////////////////////////////////

const screen_width = 1920;
const screen_height = 1080;

pub fn main() anyerror!void {

    ///////////////////////////// Window Initialization

    rl.setConfigFlags(.{ .window_transparent = true });

    rl.initWindow(screen_width, screen_height, "Application");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    rl.setExitKey(rl.KeyboardKey.key_null);

    ///////////////////////////// GPA

    var gpa__ = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa__.deinit();
    const gpa = gpa__.allocator();

    ///////////////////////////// Font

    const font_size = 40;
    const font = rl.loadFontEx("Meslo LG L DZ Regular Nerd Font Complete Mono.ttf", font_size, null);

    const font_data = try generateFontData(gpa, font);
    defer gpa.free(font_data.recs);
    defer gpa.free(font_data.glyphs);

    var font_data_index_map = try _vw.createFontDataIndexMap(gpa, font_data);
    defer font_data_index_map.deinit();

    ///////////////////////////// Camera

    var camera = rl.Camera2D{
        .offset = .{ .x = 0, .y = 0 },
        .target = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = 1,
    };

    var view_start = rl.Vector2{ .x = 0, .y = 0 };
    var view_end = rl.Vector2{ .x = screen_width, .y = screen_height };
    var view_width: f32 = screen_width;
    var view_height: f32 = screen_height;

    ///////////////////////////// New Input

    const _keyboard_setup_zone = ztracy.ZoneNC(@src(), "input setup zone", 0x00AA00);

    var vault = try _input_processor.MappingVault.init(gpa);
    defer vault.deinit();

    var editor_mode = _input_processor.EditorMode.normal;

    { // editor mode tests
        try vault.emap(&[_]Key{.j});
        try vault.emap(&[_]Key{.k});
        try vault.emap(&[_]Key{.l});
        try vault.emap(&[_]Key{.n});

        try vault.emap(&[_]Key{.a});
        try vault.emap(&[_]Key{ .l, .a });
        try vault.emap(&[_]Key{ .l, .z });
        try vault.emap(&[_]Key{ .l, .z, .c });

        try vault.emap(&[_]Key{ .left_control, .h });
        try vault.emap(&[_]Key{ .left_control, .j });
        try vault.emap(&[_]Key{ .left_control, .k });
        try vault.emap(&[_]Key{ .left_control, .l });

        try vault.emap(&[_]Key{.z});
        try vault.emap(&[_]Key{.b});
        try vault.emap(&[_]Key{.r});

        try vault.emap(&[_]Key{.m});

        try vault.nmap(&[_]Key{.h});
        try vault.nmap(&[_]Key{.j});
        try vault.nmap(&[_]Key{.k});
        try vault.nmap(&[_]Key{.l});
        try vault.nmap(&[_]Key{.m});
        try vault.nmap(&[_]Key{.b});
        try vault.nmap(&[_]Key{.w});
        try vault.nmap(&[_]Key{.e});
        try vault.nmap(&[_]Key{.zero});

        try vault.nmap(&[_]Key{.i});
        try vault.nmap(&[_]Key{.a});

        try vault.imap(&[_]Key{.escape});

        try vault.imap(&[_]Key{.a});
        try vault.imap(&[_]Key{.b});
        try vault.imap(&[_]Key{.c});
        try vault.imap(&[_]Key{.d});
        try vault.imap(&[_]Key{.e});
        try vault.imap(&[_]Key{.f});
        try vault.imap(&[_]Key{.g});
        try vault.imap(&[_]Key{.h});
        try vault.imap(&[_]Key{.i});
        try vault.imap(&[_]Key{.j});
        try vault.imap(&[_]Key{.k});
        try vault.imap(&[_]Key{.l});
        try vault.imap(&[_]Key{.m});
        try vault.imap(&[_]Key{.n});
        try vault.imap(&[_]Key{.o});
        try vault.imap(&[_]Key{.p});
        try vault.imap(&[_]Key{.q});
        try vault.imap(&[_]Key{.r});
        try vault.imap(&[_]Key{.s});
        try vault.imap(&[_]Key{.t});
        try vault.imap(&[_]Key{.u});
        try vault.imap(&[_]Key{.v});
        try vault.imap(&[_]Key{.w});
        try vault.imap(&[_]Key{.x});
        try vault.imap(&[_]Key{.y});
        try vault.imap(&[_]Key{.z});
        try vault.imap(&[_]Key{ .left_shift, .a });
        try vault.imap(&[_]Key{ .left_shift, .b });
        try vault.imap(&[_]Key{ .left_shift, .c });
        try vault.imap(&[_]Key{ .left_shift, .d });
        try vault.imap(&[_]Key{ .left_shift, .e });
        try vault.imap(&[_]Key{ .left_shift, .f });
        try vault.imap(&[_]Key{ .left_shift, .g });
        try vault.imap(&[_]Key{ .left_shift, .h });
        try vault.imap(&[_]Key{ .left_shift, .i });
        try vault.imap(&[_]Key{ .left_shift, .j });
        try vault.imap(&[_]Key{ .left_shift, .k });
        try vault.imap(&[_]Key{ .left_shift, .l });
        try vault.imap(&[_]Key{ .left_shift, .m });
        try vault.imap(&[_]Key{ .left_shift, .n });
        try vault.imap(&[_]Key{ .left_shift, .o });
        try vault.imap(&[_]Key{ .left_shift, .p });
        try vault.imap(&[_]Key{ .left_shift, .q });
        try vault.imap(&[_]Key{ .left_shift, .r });
        try vault.imap(&[_]Key{ .left_shift, .s });
        try vault.imap(&[_]Key{ .left_shift, .t });
        try vault.imap(&[_]Key{ .left_shift, .u });
        try vault.imap(&[_]Key{ .left_shift, .v });
        try vault.imap(&[_]Key{ .left_shift, .w });
        try vault.imap(&[_]Key{ .left_shift, .x });
        try vault.imap(&[_]Key{ .left_shift, .y });
        try vault.imap(&[_]Key{ .left_shift, .z });
        try vault.imap(&[_]Key{ .right_shift, .a });
        try vault.imap(&[_]Key{ .right_shift, .b });
        try vault.imap(&[_]Key{ .right_shift, .c });
        try vault.imap(&[_]Key{ .right_shift, .d });
        try vault.imap(&[_]Key{ .right_shift, .e });
        try vault.imap(&[_]Key{ .right_shift, .f });
        try vault.imap(&[_]Key{ .right_shift, .g });
        try vault.imap(&[_]Key{ .right_shift, .h });
        try vault.imap(&[_]Key{ .right_shift, .i });
        try vault.imap(&[_]Key{ .right_shift, .j });
        try vault.imap(&[_]Key{ .right_shift, .k });
        try vault.imap(&[_]Key{ .right_shift, .l });
        try vault.imap(&[_]Key{ .right_shift, .m });
        try vault.imap(&[_]Key{ .right_shift, .n });
        try vault.imap(&[_]Key{ .right_shift, .o });
        try vault.imap(&[_]Key{ .right_shift, .p });
        try vault.imap(&[_]Key{ .right_shift, .q });
        try vault.imap(&[_]Key{ .right_shift, .r });
        try vault.imap(&[_]Key{ .right_shift, .s });
        try vault.imap(&[_]Key{ .right_shift, .t });
        try vault.imap(&[_]Key{ .right_shift, .u });
        try vault.imap(&[_]Key{ .right_shift, .v });
        try vault.imap(&[_]Key{ .right_shift, .w });
        try vault.imap(&[_]Key{ .right_shift, .x });
        try vault.imap(&[_]Key{ .right_shift, .y });
        try vault.imap(&[_]Key{ .right_shift, .z });

        try vault.imap(&[_]Key{.space});
        try vault.imap(&[_]Key{ .left_shift, .space });
        try vault.imap(&[_]Key{ .right_shift, .space });

        try vault.imap(&[_]Key{.enter});

        try vault.imap(&[_]Key{.one});
        try vault.imap(&[_]Key{.two});
        try vault.imap(&[_]Key{.three});
        try vault.imap(&[_]Key{.four});
        try vault.imap(&[_]Key{.five});
        try vault.imap(&[_]Key{.six});
        try vault.imap(&[_]Key{.seven});
        try vault.imap(&[_]Key{.eight});
        try vault.imap(&[_]Key{.nine});
        try vault.imap(&[_]Key{.zero});
        try vault.imap(&[_]Key{ .left_shift, .one });
        try vault.imap(&[_]Key{ .left_shift, .two });
        try vault.imap(&[_]Key{ .left_shift, .three });
        try vault.imap(&[_]Key{ .left_shift, .four });
        try vault.imap(&[_]Key{ .left_shift, .five });
        try vault.imap(&[_]Key{ .left_shift, .six });
        try vault.imap(&[_]Key{ .left_shift, .seven });
        try vault.imap(&[_]Key{ .left_shift, .eight });
        try vault.imap(&[_]Key{ .left_shift, .nine });
        try vault.imap(&[_]Key{ .left_shift, .zero });
        try vault.imap(&[_]Key{ .right_shift, .one });
        try vault.imap(&[_]Key{ .right_shift, .two });
        try vault.imap(&[_]Key{ .right_shift, .three });
        try vault.imap(&[_]Key{ .right_shift, .four });
        try vault.imap(&[_]Key{ .right_shift, .five });
        try vault.imap(&[_]Key{ .right_shift, .six });
        try vault.imap(&[_]Key{ .right_shift, .seven });
        try vault.imap(&[_]Key{ .right_shift, .eight });
        try vault.imap(&[_]Key{ .right_shift, .nine });
        try vault.imap(&[_]Key{ .right_shift, .zero });

        try vault.imap(&[_]Key{.grave});
        try vault.imap(&[_]Key{.minus});
        try vault.imap(&[_]Key{.equal});
        try vault.imap(&[_]Key{.left_bracket});
        try vault.imap(&[_]Key{.right_bracket});
        try vault.imap(&[_]Key{.backslash});
        try vault.imap(&[_]Key{.semicolon});
        try vault.imap(&[_]Key{.apostrophe});
        try vault.imap(&[_]Key{.comma});
        try vault.imap(&[_]Key{.period});
        try vault.imap(&[_]Key{.slash});
        try vault.imap(&[_]Key{ .left_shift, .grave });
        try vault.imap(&[_]Key{ .left_shift, .minus });
        try vault.imap(&[_]Key{ .left_shift, .equal });
        try vault.imap(&[_]Key{ .left_shift, .left_bracket });
        try vault.imap(&[_]Key{ .left_shift, .right_bracket });
        try vault.imap(&[_]Key{ .left_shift, .backslash });
        try vault.imap(&[_]Key{ .left_shift, .semicolon });
        try vault.imap(&[_]Key{ .left_shift, .apostrophe });
        try vault.imap(&[_]Key{ .left_shift, .comma });
        try vault.imap(&[_]Key{ .left_shift, .period });
        try vault.imap(&[_]Key{ .left_shift, .slash });
        try vault.imap(&[_]Key{ .right_shift, .grave });
        try vault.imap(&[_]Key{ .right_shift, .minus });
        try vault.imap(&[_]Key{ .right_shift, .equal });
        try vault.imap(&[_]Key{ .right_shift, .left_bracket });
        try vault.imap(&[_]Key{ .right_shift, .right_bracket });
        try vault.imap(&[_]Key{ .right_shift, .backslash });
        try vault.imap(&[_]Key{ .right_shift, .semicolon });
        try vault.imap(&[_]Key{ .right_shift, .apostrophe });
        try vault.imap(&[_]Key{ .right_shift, .comma });
        try vault.imap(&[_]Key{ .right_shift, .period });
        try vault.imap(&[_]Key{ .right_shift, .slash });
    }

    var frame = try _input_processor.InputFrame.init(gpa);
    defer frame.deinit();

    var last_trigger_timestamp: i64 = 0;
    var last_trigger: u128 = 0;

    var reached_trigger_delay = false;
    var reached_repeat_rate = false;

    const trigger_delay = 150;
    const repeat_rate = 1000 / 62;

    _keyboard_setup_zone.End();

    ///////////////////////////// Models

    // FileNavigator

    var navigator = try FileNavigator.new(gpa);
    defer navigator.deinit();

    // Buffer & Tree Sitter & Window

    var zig_langsuite = try _neo_buffer.sitter.LangSuite.create(.zig);
    defer zig_langsuite.destroy();
    try zig_langsuite.initializeQuery();
    try zig_langsuite.initializeFilter(gpa);
    try zig_langsuite.initializeNightflyColorscheme(gpa);

    var buf = try Buffer.create(gpa, .file, "build.zig");
    try buf.initiateTreeSitter(zig_langsuite);
    defer buf.destroy();

    const win_padding = 20;
    const win_width = @as(f32, @floatFromInt(screen_width)) / 1.3;
    const win_height = screen_height - win_padding / 2;
    const win_x = screen_width - win_width;

    // var window = try Window.spawn(gpa, buf, font_size, win_x, win_padding, .{
    //     .width = win_width,
    //     .height = win_height,
    // });
    var window = try Window.spawn(gpa, buf, font_size, 400, 100, null);
    defer window.destroy();

    const window_dragger_y_offset = -40;
    var move_window_with_mouse = false;

    var move_window_with_keyboard = false;
    var resize_window_bounds_with_keyboard = false;

    ////////////////////////////////////////////////////////////////////////////////////////////// Game Loop

    while (!rl.windowShouldClose()) {

        ///////////////////////////// Camera

        // drag while holding Right Mouse Button
        if (rl.isMouseButtonDown(.mouse_button_right)) {
            var delta = rl.getMouseDelta();
            delta = delta.scale(-1 / camera.zoom);
            camera.target = delta.add(camera.target);
        }

        { // zoom with scroll wheel
            const wheel = rl.getMouseWheelMove();
            if (wheel != 0) {
                const mouse_pos = rl.getMousePosition();
                const mouse_world_pos = rl.getScreenToWorld2D(mouse_pos, camera);
                camera.offset = mouse_pos;
                camera.target = mouse_world_pos;

                var scale_factor = 1 + (0.25 * @abs(wheel));
                if (wheel < 0) scale_factor = 1 / scale_factor;
                camera.zoom = rl.math.clamp(camera.zoom * scale_factor, 0.125, 64);
            }
        }

        { // update screen bounding box variables
            view_start = rl.getScreenToWorld2D(.{ .x = 0, .y = 0 }, camera);
            view_end = rl.getScreenToWorld2D(.{ .x = screen_width, .y = screen_height }, camera);
            view_width = view_end.x - view_start.x;
            view_height = view_end.y - view_start.y;
        }

        ///////////////////////////// Keyboard

        blk: {
            const zone = ztracy.ZoneNC(@src(), "Keyboard loop zone", 0x00AAFF);
            defer zone.End();

            var i: usize = frame.downs.items.len;
            while (i > 0) {
                i -= 1;
                const code: c_int = @intCast(@intFromEnum(frame.downs.items[i].key));
                const key: rl.KeyboardKey = @enumFromInt(code);
                if (rl.isKeyUp(key)) {
                    try frame.keyUp(frame.downs.items[i].key);

                    // std.debug.print("up it!\n", .{});
                    reached_trigger_delay = false;
                    reached_repeat_rate = false;
                }
            }

            for (_input_processor.Key.values) |value| {
                const code: c_int = @intCast(value);
                if (rl.isKeyDown(@enumFromInt(code))) {
                    const enum_value: _input_processor.Key = @enumFromInt(value);
                    try frame.keyDown(enum_value, .now);
                }
            }

            if (_input_processor.produceTrigger(
                editor_mode,
                &frame,
                _input_processor.MappingVault.down_checker,
                _input_processor.MappingVault.up_checker,
                vault,
            )) |trigger| {
                // std.debug.print("trigger: 0x{x}\n", .{trigger});
                const current_time = std.time.milliTimestamp();
                defer last_trigger = trigger;

                if (trigger != last_trigger) {
                    reached_trigger_delay = false;
                    reached_repeat_rate = false;
                    last_trigger_timestamp = 0;
                }

                trigger: {
                    if (reached_repeat_rate) {
                        if (current_time - last_trigger_timestamp < repeat_rate) break :blk;
                        last_trigger_timestamp = current_time;
                        break :trigger;
                    }

                    if (reached_trigger_delay) {
                        if (current_time - last_trigger_timestamp < trigger_delay) break :blk;
                        reached_repeat_rate = true;
                        last_trigger_timestamp = current_time;
                        break :trigger;
                    }

                    if (current_time - last_trigger_timestamp < trigger_delay) break :blk;
                    reached_trigger_delay = true;
                    last_trigger_timestamp = current_time;
                }

                switch (editor_mode) {
                    .editor => {
                        switch (trigger) {
                            hash(&[_]Key{.a}) => {
                                std.debug.print("Alice in Wonderland\n", .{});
                            },

                            hash(&[_]Key{.n}) => navigator.toggle(),

                            hash(&[_]Key{ .left_control, .h }) => try navigator.backwards(),
                            hash(&[_]Key{ .left_control, .k }) => navigator.moveUp(),
                            hash(&[_]Key{ .left_control, .j }) => navigator.moveDown(),
                            hash(&[_]Key{ .left_control, .l }) => {
                                if (try navigator.forward()) |path| {
                                    defer path.deinit();

                                    buf.destroy();
                                    window.destroy();

                                    buf = try Buffer.create(gpa, .file, path.items);
                                    try buf.initiateTreeSitter(zig_langsuite);
                                    window = try Window.spawn(gpa, buf, font_size, win_x, win_padding, .{
                                        .width = win_width,
                                        .height = win_height,
                                    });
                                }
                            },

                            hash(&[_]Key{.z}) => move_window_with_keyboard = true,
                            hash(&[_]Key{.b}) => window.toggleBounds(),
                            hash(&[_]Key{.r}) => resize_window_bounds_with_keyboard = true,

                            hash(&[_]Key{.m}) => editor_mode = .normal,

                            else => {},
                        }
                    },
                    .normal => {
                        switch (trigger) {
                            hash(&[_]Key{.h}) => window.moveCursorLeft(&window.cursor),
                            hash(&[_]Key{.j}) => window.moveCursorDown(&window.cursor),
                            hash(&[_]Key{.k}) => window.moveCursorUp(&window.cursor),
                            hash(&[_]Key{.l}) => window.moveCursorRight(&window.cursor),

                            hash(&[_]Key{.b}) => window.vimBackwards(.start, &window.cursor),
                            hash(&[_]Key{.w}) => window.vimForward(.start, &window.cursor),
                            hash(&[_]Key{.e}) => window.vimForward(.end, &window.cursor),

                            hash(&[_]Key{.zero}) => window.cursor.set(window.cursor.line, 0),

                            hash(&[_]Key{.i}) => editor_mode = .insert,
                            hash(&[_]Key{.a}) => {
                                window.is_in_AFTER_insert_mode = true;
                                window.moveCursorRight(&window.cursor);
                                editor_mode = .insert;
                            },
                            hash(&[_]Key{.m}) => editor_mode = .editor,
                            else => {},
                        }
                    },
                    .insert => {
                        switch (trigger) {
                            hash(&[_]Key{.a}) => try window.insertChars("a"),
                            hash(&[_]Key{.b}) => try window.insertChars("b"),
                            hash(&[_]Key{.c}) => try window.insertChars("c"),
                            hash(&[_]Key{.d}) => try window.insertChars("d"),
                            hash(&[_]Key{.e}) => try window.insertChars("e"),
                            hash(&[_]Key{.f}) => try window.insertChars("f"),
                            hash(&[_]Key{.g}) => try window.insertChars("g"),
                            hash(&[_]Key{.h}) => try window.insertChars("h"),
                            hash(&[_]Key{.i}) => try window.insertChars("i"),
                            hash(&[_]Key{.j}) => try window.insertChars("j"),
                            hash(&[_]Key{.k}) => try window.insertChars("k"),
                            hash(&[_]Key{.l}) => try window.insertChars("l"),
                            hash(&[_]Key{.m}) => try window.insertChars("m"),
                            hash(&[_]Key{.n}) => try window.insertChars("n"),
                            hash(&[_]Key{.o}) => try window.insertChars("o"),
                            hash(&[_]Key{.p}) => try window.insertChars("p"),
                            hash(&[_]Key{.q}) => try window.insertChars("q"),
                            hash(&[_]Key{.r}) => try window.insertChars("r"),
                            hash(&[_]Key{.s}) => try window.insertChars("s"),
                            hash(&[_]Key{.t}) => try window.insertChars("t"),
                            hash(&[_]Key{.u}) => try window.insertChars("u"),
                            hash(&[_]Key{.v}) => try window.insertChars("v"),
                            hash(&[_]Key{.w}) => try window.insertChars("w"),
                            hash(&[_]Key{.x}) => try window.insertChars("x"),
                            hash(&[_]Key{.y}) => try window.insertChars("y"),
                            hash(&[_]Key{.z}) => try window.insertChars("z"),
                            hash(&[_]Key{ .left_shift, .a }) => try window.insertChars("A"),
                            hash(&[_]Key{ .left_shift, .b }) => try window.insertChars("B"),
                            hash(&[_]Key{ .left_shift, .c }) => try window.insertChars("C"),
                            hash(&[_]Key{ .left_shift, .d }) => try window.insertChars("D"),
                            hash(&[_]Key{ .left_shift, .e }) => try window.insertChars("E"),
                            hash(&[_]Key{ .left_shift, .f }) => try window.insertChars("F"),
                            hash(&[_]Key{ .left_shift, .g }) => try window.insertChars("G"),
                            hash(&[_]Key{ .left_shift, .h }) => try window.insertChars("H"),
                            hash(&[_]Key{ .left_shift, .i }) => try window.insertChars("I"),
                            hash(&[_]Key{ .left_shift, .j }) => try window.insertChars("J"),
                            hash(&[_]Key{ .left_shift, .k }) => try window.insertChars("K"),
                            hash(&[_]Key{ .left_shift, .l }) => try window.insertChars("L"),
                            hash(&[_]Key{ .left_shift, .m }) => try window.insertChars("M"),
                            hash(&[_]Key{ .left_shift, .n }) => try window.insertChars("N"),
                            hash(&[_]Key{ .left_shift, .o }) => try window.insertChars("O"),
                            hash(&[_]Key{ .left_shift, .p }) => try window.insertChars("P"),
                            hash(&[_]Key{ .left_shift, .q }) => try window.insertChars("Q"),
                            hash(&[_]Key{ .left_shift, .r }) => try window.insertChars("R"),
                            hash(&[_]Key{ .left_shift, .s }) => try window.insertChars("S"),
                            hash(&[_]Key{ .left_shift, .t }) => try window.insertChars("T"),
                            hash(&[_]Key{ .left_shift, .u }) => try window.insertChars("U"),
                            hash(&[_]Key{ .left_shift, .v }) => try window.insertChars("V"),
                            hash(&[_]Key{ .left_shift, .w }) => try window.insertChars("W"),
                            hash(&[_]Key{ .left_shift, .x }) => try window.insertChars("X"),
                            hash(&[_]Key{ .left_shift, .y }) => try window.insertChars("Y"),
                            hash(&[_]Key{ .left_shift, .z }) => try window.insertChars("Z"),
                            hash(&[_]Key{ .right_shift, .a }) => try window.insertChars("A"),
                            hash(&[_]Key{ .right_shift, .b }) => try window.insertChars("B"),
                            hash(&[_]Key{ .right_shift, .c }) => try window.insertChars("C"),
                            hash(&[_]Key{ .right_shift, .d }) => try window.insertChars("D"),
                            hash(&[_]Key{ .right_shift, .e }) => try window.insertChars("E"),
                            hash(&[_]Key{ .right_shift, .f }) => try window.insertChars("F"),
                            hash(&[_]Key{ .right_shift, .g }) => try window.insertChars("G"),
                            hash(&[_]Key{ .right_shift, .h }) => try window.insertChars("H"),
                            hash(&[_]Key{ .right_shift, .i }) => try window.insertChars("I"),
                            hash(&[_]Key{ .right_shift, .j }) => try window.insertChars("J"),
                            hash(&[_]Key{ .right_shift, .k }) => try window.insertChars("K"),
                            hash(&[_]Key{ .right_shift, .l }) => try window.insertChars("L"),
                            hash(&[_]Key{ .right_shift, .m }) => try window.insertChars("M"),
                            hash(&[_]Key{ .right_shift, .n }) => try window.insertChars("N"),
                            hash(&[_]Key{ .right_shift, .o }) => try window.insertChars("O"),
                            hash(&[_]Key{ .right_shift, .p }) => try window.insertChars("P"),
                            hash(&[_]Key{ .right_shift, .q }) => try window.insertChars("Q"),
                            hash(&[_]Key{ .right_shift, .r }) => try window.insertChars("R"),
                            hash(&[_]Key{ .right_shift, .s }) => try window.insertChars("S"),
                            hash(&[_]Key{ .right_shift, .t }) => try window.insertChars("T"),
                            hash(&[_]Key{ .right_shift, .u }) => try window.insertChars("U"),
                            hash(&[_]Key{ .right_shift, .v }) => try window.insertChars("V"),
                            hash(&[_]Key{ .right_shift, .w }) => try window.insertChars("W"),
                            hash(&[_]Key{ .right_shift, .x }) => try window.insertChars("X"),
                            hash(&[_]Key{ .right_shift, .y }) => try window.insertChars("Y"),
                            hash(&[_]Key{ .right_shift, .z }) => try window.insertChars("Z"),

                            hash(&[_]Key{.space}) => try window.insertChars(" "),
                            hash(&[_]Key{ .left_shift, .space }) => try window.insertChars(" "),
                            hash(&[_]Key{ .right_shift, .space }) => try window.insertChars(" "),

                            // TODO: investigate the buggy behavior when inserting \n

                            hash(&[_]Key{.enter}) => try window.insertChars("\n"),

                            hash(&[_]Key{.one}) => try window.insertChars("1"),
                            hash(&[_]Key{.two}) => try window.insertChars("2"),
                            hash(&[_]Key{.three}) => try window.insertChars("3"),
                            hash(&[_]Key{.four}) => try window.insertChars("4"),
                            hash(&[_]Key{.five}) => try window.insertChars("5"),
                            hash(&[_]Key{.six}) => try window.insertChars("6"),
                            hash(&[_]Key{.seven}) => try window.insertChars("7"),
                            hash(&[_]Key{.eight}) => try window.insertChars("8"),
                            hash(&[_]Key{.nine}) => try window.insertChars("9"),
                            hash(&[_]Key{.zero}) => try window.insertChars("0"),
                            hash(&[_]Key{ .left_shift, .one }) => try window.insertChars("!"),
                            hash(&[_]Key{ .left_shift, .two }) => try window.insertChars("@"),
                            hash(&[_]Key{ .left_shift, .three }) => try window.insertChars("#"),
                            hash(&[_]Key{ .left_shift, .four }) => try window.insertChars("$"),
                            hash(&[_]Key{ .left_shift, .five }) => try window.insertChars("%"),
                            hash(&[_]Key{ .left_shift, .six }) => try window.insertChars("^"),
                            hash(&[_]Key{ .left_shift, .seven }) => try window.insertChars("&"),
                            hash(&[_]Key{ .left_shift, .eight }) => try window.insertChars("*"),
                            hash(&[_]Key{ .left_shift, .nine }) => try window.insertChars("("),
                            hash(&[_]Key{ .left_shift, .zero }) => try window.insertChars(")"),
                            hash(&[_]Key{ .right_shift, .one }) => try window.insertChars("!"),
                            hash(&[_]Key{ .right_shift, .two }) => try window.insertChars("@"),
                            hash(&[_]Key{ .right_shift, .three }) => try window.insertChars("#"),
                            hash(&[_]Key{ .right_shift, .four }) => try window.insertChars("$"),
                            hash(&[_]Key{ .right_shift, .five }) => try window.insertChars("%"),
                            hash(&[_]Key{ .right_shift, .six }) => try window.insertChars("^"),
                            hash(&[_]Key{ .right_shift, .seven }) => try window.insertChars("&"),
                            hash(&[_]Key{ .right_shift, .eight }) => try window.insertChars("*"),
                            hash(&[_]Key{ .right_shift, .nine }) => try window.insertChars("("),
                            hash(&[_]Key{ .right_shift, .zero }) => try window.insertChars(")"),

                            hash(&[_]Key{.grave}) => try window.insertChars("`"),
                            hash(&[_]Key{.minus}) => try window.insertChars("-"),
                            hash(&[_]Key{.equal}) => try window.insertChars("="),
                            hash(&[_]Key{.left_bracket}) => try window.insertChars("["),
                            hash(&[_]Key{.right_bracket}) => try window.insertChars("]"),
                            hash(&[_]Key{.backslash}) => try window.insertChars("\\"),
                            hash(&[_]Key{.semicolon}) => try window.insertChars(";"),
                            hash(&[_]Key{.apostrophe}) => try window.insertChars("'"),
                            hash(&[_]Key{.comma}) => try window.insertChars(","),
                            hash(&[_]Key{.period}) => try window.insertChars("."),
                            hash(&[_]Key{.slash}) => try window.insertChars("/"),
                            hash(&[_]Key{ .left_shift, .grave }) => try window.insertChars("~"),
                            hash(&[_]Key{ .left_shift, .minus }) => try window.insertChars("_"),
                            hash(&[_]Key{ .left_shift, .equal }) => try window.insertChars("+"),
                            hash(&[_]Key{ .left_shift, .left_bracket }) => try window.insertChars("{"),
                            hash(&[_]Key{ .left_shift, .right_bracket }) => try window.insertChars("}"),
                            hash(&[_]Key{ .left_shift, .backslash }) => try window.insertChars("|"),
                            hash(&[_]Key{ .left_shift, .semicolon }) => try window.insertChars(":"),
                            hash(&[_]Key{ .left_shift, .apostrophe }) => try window.insertChars("\""),
                            hash(&[_]Key{ .left_shift, .comma }) => try window.insertChars("<"),
                            hash(&[_]Key{ .left_shift, .period }) => try window.insertChars(">"),
                            hash(&[_]Key{ .left_shift, .slash }) => try window.insertChars("?"),
                            hash(&[_]Key{ .right_shift, .grave }) => try window.insertChars("~"),
                            hash(&[_]Key{ .right_shift, .minus }) => try window.insertChars("_"),
                            hash(&[_]Key{ .right_shift, .equal }) => try window.insertChars("+"),
                            hash(&[_]Key{ .right_shift, .left_bracket }) => try window.insertChars("{"),
                            hash(&[_]Key{ .right_shift, .right_bracket }) => try window.insertChars("}"),
                            hash(&[_]Key{ .right_shift, .backslash }) => try window.insertChars("|"),
                            hash(&[_]Key{ .right_shift, .semicolon }) => try window.insertChars(":"),
                            hash(&[_]Key{ .right_shift, .apostrophe }) => try window.insertChars("\""),
                            hash(&[_]Key{ .right_shift, .comma }) => try window.insertChars("<"),
                            hash(&[_]Key{ .right_shift, .period }) => try window.insertChars(">"),
                            hash(&[_]Key{ .right_shift, .slash }) => try window.insertChars("?"),

                            hash(&[_]Key{.escape}) => {
                                window.is_in_AFTER_insert_mode = false;
                                window.moveCursorLeft(&window.cursor);
                                editor_mode = .normal;
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            } else {
                move_window_with_keyboard = false;
                resize_window_bounds_with_keyboard = false;
            }
        }

        // window handle
        const mouse = rl.getScreenToWorld2D(rl.getMousePosition(), camera);
        const collides = rl.checkCollisionPointCircle(mouse, .{ .x = window.x, .y = window.y + window_dragger_y_offset }, 30);
        if (collides and rl.isMouseButtonDown(.mouse_button_left)) {
            move_window_with_mouse = true;
        }
        if (move_window_with_mouse) {
            window.x = mouse.x;
            window.y = mouse.y - window_dragger_y_offset;
            if (rl.isMouseButtonReleased(.mouse_button_left)) {
                move_window_with_mouse = false;
            }
        }
        if (move_window_with_keyboard) {
            const mouse_delta = rl.getMouseDelta().scale(1 / camera.zoom);
            window.x += mouse_delta.x;
            window.y += mouse_delta.y;
        }
        if (resize_window_bounds_with_keyboard and window.bounded) {
            const mouse_delta = rl.getMouseDelta().scale(1 / camera.zoom);
            window.bounds.width += mouse_delta.x;
            window.bounds.height += mouse_delta.y;
        }

        ///////////////////////////// Draw

        rl.beginDrawing();
        defer rl.endDrawing();
        {
            // rl.drawFPS(10, 10);
            rl.clearBackground(rl.Color.blank);

            // navigator
            if (navigator.is_visible) {
                for (navigator.short_paths, 0..) |path, i| {
                    const text = try std.fmt.allocPrintZ(gpa, "{s}", .{path});
                    defer gpa.free(text);
                    const idx: i32 = @intCast(i);
                    const color = if (i == navigator.index) rl.Color.sky_blue else rl.Color.ray_white;
                    rl.drawText(text, 70, 100 + idx * 40, 30, color);
                }
            }

            { // mode indicator
                rl.drawText(@tagName(editor_mode), 40, screen_height - 30 * 2, 30, rl.Color.ray_white);
            }

            var chars_rendered: u64 = 0;
            // defer ztracy.PlotU("chars_rendered", chars_rendered);

            { // window content
                rl.beginMode2D(camera);
                defer rl.endMode2D();

                var last_y: f32 = undefined;

                var iter = window.codePointIter(font_data, font_data_index_map, .{
                    .start_x = view_start.x,
                    .start_y = view_start.y,
                    .end_x = view_end.x,
                    .end_y = view_end.y,
                });

                while (iter.next()) |result| {
                    switch (result) {
                        .code_point => |char| {
                            rl.drawTextCodepoint(font, char.value, .{ .x = char.x, .y = char.y }, font_size, rl.Color.fromInt(char.color));
                            chars_rendered += 1;

                            if (iter.current_line + window.contents.start_line == window.cursor.line) {
                                if (iter.current_col -| 1 == window.cursor.col) {
                                    rl.drawRectangle(@intFromFloat(char.x), @intFromFloat(char.y), @intFromFloat(char.char_width), font_size, rl.Color.ray_white);
                                }
                                if (iter.current_col == window.cursor.col) {
                                    rl.drawRectangle(@intFromFloat(char.x + char.char_width), @intFromFloat(char.y), @intFromFloat(char.char_width), font_size, rl.Color.ray_white);
                                }
                            }

                            last_y = char.y;
                        },
                        .skip_to_new_line => {
                            if (iter.current_line + window.contents.start_line == window.cursor.line and
                                window.contents.lines[iter.current_line].len == 0 and
                                iter.current_col == 0)
                            {
                                rl.drawRectangle(@intFromFloat(window.x), @intFromFloat(last_y + font_size), 15, font_size, rl.Color.ray_white);
                            }
                            defer last_y += font_size;
                        },
                        else => continue,
                    }
                }

                // { // Window dragger
                //     const radius: f32 = if (collides) 40 else 30;
                //     rl.drawCircle(
                //         @intFromFloat(window.x),
                //         @intFromFloat(window.y + window_dragger_y_offset),
                //         radius,
                //         rl.Color.sky_blue,
                //     );
                // }

                // { // Window bounded bottom indicator
                //     if (window.bounded) {
                //         const radius = 30;
                //         rl.drawCircle(
                //             @intFromFloat(window.x + window.bounds.width + radius / 2),
                //             @intFromFloat(window.y + window.bounds.height + radius / 2),
                //             radius,
                //             rl.Color.yellow,
                //         );
                //     }
                // }
            }

            // try drawTextAtBottomRight(
            //     "chars rendered: {d}",
            //     .{chars_rendered},
            //     30,
            //     .{ .x = 40, .y = 40 },
            // );

            try drawTextAtBottomRight(
                "[{d}, {d}]",
                .{ window.cursor.line, window.cursor.col },
                30,
                .{ .x = 40, .y = 120 },
            );
        }
    }
}

fn drawTextAtBottomRight(comptime fmt: []const u8, args: anytype, font_size: i32, offset: rl.Vector2) !void {
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrintZ(&buf, fmt, args);
    const measure = rl.measureText(text, font_size);
    const x = screen_width - measure - @as(i32, @intFromFloat(offset.x));
    const y = screen_height - font_size - @as(i32, @intFromFloat(offset.y));
    rl.drawText(text, x, y, font_size, rl.Color.ray_white);
}

fn generateFontData(a: Allocator, font: rl.Font) !_vw.FontData {
    var recs = try a.alloc(_vw.Rectangle, @intCast(font.glyphCount));
    var glyphs = try a.alloc(_vw.GlyphData, @intCast(font.glyphCount));

    for (0..@intCast(font.glyphCount)) |i| {
        recs[i] = _vw.Rectangle{
            .x = font.recs[i].x,
            .y = font.recs[i].y,
            .width = font.recs[i].width,
            .height = font.recs[i].height,
        };

        glyphs[i] = _vw.GlyphData{
            .advanceX = font.glyphs[i].advanceX,
            .offsetX = @intCast(font.glyphs[i].offsetX),
            .value = font.glyphs[i].value,
        };
    }

    return .{
        .base_size = font.baseSize,
        .glyph_padding = font.glyphPadding,
        .recs = recs,
        .glyphs = glyphs,
    };
}
