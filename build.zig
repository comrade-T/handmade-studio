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

const std = @import("std");

pub const BuildOpts = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bops = BuildOpts{ .b = b, .target = target, .optimize = optimize };
    const zig_build_test_step = b.step("test", "Zig Build Test");

    ////////////////////////////////////////////////////////////////////////////// Dependencies

    // const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });
    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });

    const mvzr = b.dependency("mvzr", .{ .target = target, .optimize = optimize }).module("mvzr");

    const raylib = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });

    const s2s = b.addModule("s2s", .{ .root_source_file = b.path("copied-libs/s2s.zig") });
    _ = s2s;

    const ztracy_options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_fibers = b.option(
            bool,
            "enable_fibers",
            "Enable Tracy fiber support",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "on_demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = ztracy_options.enable_ztracy,
        .enable_fibers = ztracy_options.enable_fibers,
        .on_demand = ztracy_options.on_demand,
    });

    // const ztracy = b.dependency("ztracy", .{
    //     .enable_ztracy = true,
    //     .enable_fibers = true,
    // });

    const fuzzig = b.dependency("fuzzig", .{}).module("fuzzig");

    ////////////////////////////////////////////////////////////////////////////// Tree Sitter

    const tree_sitter = b.addStaticLibrary(.{
        .name = "tree-sitter",
        .target = target,
        .optimize = optimize,
    });

    tree_sitter.linkLibC();
    tree_sitter.linkLibCpp();
    tree_sitter.addIncludePath(b.path("submodules/tree-sitter/lib/include"));
    tree_sitter.addIncludePath(b.path("submodules/tree-sitter/lib/src"));
    tree_sitter.addCSourceFiles(.{ .files = &.{"submodules/tree-sitter/lib/src/lib.c"}, .flags = &flags });

    addParser(b, tree_sitter, "zig", null);

    b.installArtifact(tree_sitter);
    tree_sitter.installHeadersDirectory(b.path("submodules/tree-sitter/lib/include/tree_sitter"), "tree_sitter", .{});

    ////////////////////////////////////////////////////////////////////////////// Local Modules

    const input_processor = addTestableModule(&bops, "src/keyboard/input_processor.zig", &.{}, zig_build_test_step);

    const ropeman = addTestableModule(&bops, "src/buffer/RopeMan.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const query_filter = addTestableModule(&bops, "src/tree-sitter/QueryFilter.zig", &.{
        .{ .name = "mvzr", .module = mvzr },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        .{ .name = "RopeMan", .module = ropeman.module },
    }, zig_build_test_step);
    query_filter.compile.linkLibrary(tree_sitter);

    const langsuite = addTestableModule(&bops, "src/tree-sitter/LangSuite.zig", &.{
        .{ .name = "mvzr", .module = mvzr },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        .{ .name = "RopeMan", .module = ropeman.module },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    langsuite.module.linkLibrary(tree_sitter);

    const rc_rope = addTestableModule(&bops, "src/buffer/RcRope.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    _ = rc_rope;

    const buffer = addTestableModule(&bops, "src/buffer/Buffer.zig", &.{
        .{ .name = "RopeMan", .module = ropeman.module },
        .{ .name = "LangSuite", .module = langsuite.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const linked_list = addTestableModule(&bops, "src/window/LinkedList.zig", &.{}, zig_build_test_step);
    _ = linked_list;

    const cursor_manager = addTestableModule(&bops, "src/window/CursorManager.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "RopeMan", .module = ropeman.module },
    }, zig_build_test_step);

    const window_source = addTestableModule(&bops, "src/window/WindowSource.zig", &.{
        .{ .name = "Buffer", .module = buffer.module },
        .{ .name = "LangSuite", .module = langsuite.module },
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "CursorManager", .module = cursor_manager.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const colorscheme_store = addTestableModule(&bops, "src/window/ColorschemeStore.zig", &.{}, zig_build_test_step);
    const font_store = addTestableModule(&bops, "src/window/FontStore.zig", &.{}, zig_build_test_step);
    const render_mall = addTestableModule(&bops, "src/window/RenderMall.zig", &.{
        .{ .name = "FontStore", .module = font_store.module },
        .{ .name = "ColorschemeStore", .module = colorscheme_store.module },
    }, zig_build_test_step);

    const quad_tree = addTestableModule(&bops, "src/window/WindowManager/QuadTree.zig", &.{
        .{ .name = "RenderMall", .module = render_mall.module },
    }, zig_build_test_step);

    const window = addTestableModule(&bops, "src/window/Window.zig", &.{
        .{ .name = "ztracy", .module = ztracy.module("root") },
        .{ .name = "LangSuite", .module = langsuite.module },
        .{ .name = "WindowSource", .module = window_source.module },
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "CursorManager", .module = cursor_manager.module },
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "QuadTree", .module = quad_tree.module },
    }, zig_build_test_step);

    const anchor_picker = addTestableModule(&bops, "src/components/AnchorPicker.zig", &.{
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "input_processor", .module = input_processor.module },
    }, zig_build_test_step);

    const notification_line = addTestableModule(&bops, "src/components/NotificationLine.zig", &.{
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    const window_manager = addTestableModule(&bops, "src/window/WindowManager.zig", &.{
        .{ .name = "ztracy", .module = ztracy.module("root") },
        .{ .name = "LangSuite", .module = langsuite.module },
        .{ .name = "WindowSource", .module = window_source.module },
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "Window", .module = window.module },
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "AnchorPicker", .module = anchor_picker.module },
        .{ .name = "QuadTree", .module = quad_tree.module },
    }, zig_build_test_step);

    const department_of_inputs = addTestableModule(&bops, "src/components/DepartmentOfInputs.zig", &.{
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "WindowSource", .module = window_source.module },
        .{ .name = "Window", .module = window.module },
        .{ .name = "input_processor", .module = input_processor.module },
    }, zig_build_test_step);

    ///////////////////////////// Fuzzy Finder

    const text_box = addTestableModule(&bops, "src/components/TextBox.zig", &.{
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "RopeMan", .module = ropeman.module },
        .{ .name = "CursorManager", .module = cursor_manager.module },
        .{ .name = "RenderMall", .module = render_mall.module },
    }, zig_build_test_step);
    _ = text_box;

    const confirmation_prompt = addTestableModule(&bops, "src/components/ConfirmationPrompt.zig", &.{
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    ///////////////////////////// SessionManager

    const session = addTestableModule(&bops, "src/session/Session.zig", &.{
        .{ .name = "WindowManager", .module = window_manager.module },
        .{ .name = "NotificationLine", .module = notification_line.module },
        .{ .name = "AnchorPicker", .module = anchor_picker.module },
        .{ .name = "input_processor", .module = input_processor.module },
    }, zig_build_test_step);

    const fuzzy_finders = addTestableModule(&bops, "src/components/FuzzyFinder/fuzzy_finders.zig", &.{
        .{ .name = "fuzzig", .module = fuzzig },
        .{ .name = "WindowSource", .module = window_source.module },
        .{ .name = "Window", .module = window.module },
        .{ .name = "RenderMall", .module = render_mall.module },
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "AnchorPicker", .module = anchor_picker.module },
        .{ .name = "DepartmentOfInputs", .module = department_of_inputs.module },
        .{ .name = "ConfirmationPrompt", .module = confirmation_prompt.module },
        .{ .name = "NotificationLine", .module = notification_line.module },
        .{ .name = "Buffer", .module = buffer.module },
        .{ .name = "Session", .module = session.module },
    }, zig_build_test_step);

    ////////////////////////////////////////////////////////////////////////////// Executables

    ///////////////////////////// Main

    {
        const exe_name = b.option(
            []const u8,
            "exe_name",
            "Name of the executable",
        ) orelse "main";

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("input_processor", input_processor.module);
        exe.root_module.addImport("LangSuite", langsuite.module);
        exe.root_module.addImport("Window", window.module);
        exe.root_module.addImport("FontStore", font_store.module);
        exe.root_module.addImport("ColorschemeStore", colorscheme_store.module);
        exe.root_module.addImport("RenderMall", render_mall.module);
        exe.root_module.addImport("WindowManager", window_manager.module);

        exe.root_module.addImport("fuzzy_finders", fuzzy_finders.module);

        exe.root_module.addImport("AnchorPicker", anchor_picker.module);

        exe.root_module.addImport("DepartmentOfInputs", department_of_inputs.module);
        exe.root_module.addImport("ConfirmationPrompt", confirmation_prompt.module);
        exe.root_module.addImport("NotificationLine", notification_line.module);

        exe.root_module.addImport("Session", session.module);

        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(ztracy.artifact("tracy"));

        exe.linkLibrary(raylib.artifact("raylib"));
        exe.root_module.addImport("raylib", raylib.module("raylib"));

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("run", "Run Application");
        run_step.dependOn(&run_cmd.step);
    }

    ///////////////////////////// Experiments

    {
        const path = "src/demos/spawn_rec_by_clicking.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "spawn_rec_by_clicking", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/camera2d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "camera2d_example", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/drag_camera_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "drag_camera_example", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/camera3d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "camera3d_example", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/bunnymark.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "bunnymark", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/moving_dot.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "camera3d_example", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/child_process.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "child_process", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/threads.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{ .name = "threads", .root_source_file = b.path(path), .target = target, .optimize = optimize });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
}

//////////////////////////////////////////////////////////////////////////////////////////////

fn addRunnableRaylibFile(b: *std.Build, compile: *std.Build.Step.Compile, raylib: *std.Build.Dependency, path: []const u8) void {
    compile.linkLibrary(raylib.artifact("raylib"));
    compile.root_module.addImport("raylib", raylib.module("raylib"));

    const run_cmd = b.addRunArtifact(compile);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step(path, path);
    run_step.dependOn(&run_cmd.step);
}

//////////////////////////////////////////////////////////////////////////////////////////////

const TestableModule = struct {
    module: *std.Build.Module,
    compile: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

fn addTestableModule(bops: *const BuildOpts, path: []const u8, imports: []const std.Build.Module.Import, test_step: *std.Build.Step) TestableModule {
    const module = bops.b.createModule(.{
        .root_source_file = bops.b.path(path),
        .imports = imports,
    });
    const compile = bops.b.addTest(.{
        .root_source_file = bops.b.path(path),
        .target = bops.target,
        .optimize = bops.optimize,
    });
    for (imports) |imp| {
        compile.root_module.addImport(imp.name, imp.module);
    }
    const run = bops.b.addRunArtifact(compile);

    var buf: [255]u8 = undefined;
    const individual_test_step_name = std.fmt.bufPrint(&buf, "test {s}", .{path}) catch unreachable;
    const individual_test_step = bops.b.step(individual_test_step_name, "Run unit tests");
    individual_test_step.dependOn(&run.step);

    test_step.dependOn(&run.step);
    return TestableModule{
        .module = module,
        .compile = compile,
        .run = run,
    };
}

//////////////////////////////////////////////////////////////////////////////////////////////

const flags = [_][]const u8{
    "-fno-sanitize=undefined",
};

fn addParser(b: *std.Build, lib: *std.Build.Step.Compile, comptime lang: []const u8, comptime subdir: ?[]const u8) void {
    const basedir = "submodules/tree-sitter-" ++ lang;
    const srcdir = if (subdir) |sub| basedir ++ "/" ++ sub ++ "/src" else basedir ++ "/src";
    const qrydir = if (subdir) |sub| if (exists(b, basedir ++ "/" ++ sub ++ "/queries")) basedir ++ "/" ++ sub ++ "/queries" else basedir ++ "/queries" else basedir ++ "/queries";
    const parser = srcdir ++ "/parser.c";
    const scanner = srcdir ++ "/scanner.c";
    const scanner_cc = srcdir ++ "/scanner.cc";

    lib.addCSourceFiles(.{ .files = &.{parser}, .flags = &flags });
    if (exists(b, scanner_cc))
        lib.addCSourceFiles(.{ .files = &.{scanner_cc}, .flags = &flags });
    if (exists(b, scanner))
        lib.addCSourceFiles(.{ .files = &.{scanner}, .flags = &flags });
    lib.addIncludePath(b.path(srcdir));

    if (exists(b, qrydir)) {
        b.installDirectory(.{
            .source_dir = b.path(qrydir),
            .include_extensions = &[_][]const u8{".scm"},
            .install_dir = .{ .custom = "queries" },
            .install_subdir = lang,
        });
    }
}

fn exists(b: *std.Build, path: []const u8) bool {
    std.fs.cwd().access(b.pathFromRoot(path), .{ .mode = .read_only }) catch return false;
    return true;
}

fn ts_queryfile(b: *std.Build, comptime path: []const u8) std.Build.Module.Import {
    return .{
        .name = path,
        .module = b.createModule(.{
            .root_source_file = b.path(path),
        }),
    };
}
