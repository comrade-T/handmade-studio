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
    const raylib = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });

    const regex = b.addModule("regex", .{ .root_source_file = b.path("submodules/regex/src/regex.zig") });

    const s2s = b.addModule("s2s", .{ .root_source_file = b.path("copied-libs/s2s.zig") });

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = true,
        .enable_fibers = true,
    });

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

    ////////////////////////////////////////////////////////////////////////////// Local Modules - New

    const query_filter = addTestableModule(&bops, "src/tree-sitter/QueryFilter.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    query_filter.compile.linkLibrary(tree_sitter);

    const langsuite = addTestableModule(&bops, "src/tree-sitter/LangSuite.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    langsuite.module.linkLibrary(tree_sitter);

    const style_parser = addTestableModule(&bops, "src/tree-sitter/StyleParser.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    style_parser.compile.linkLibrary(tree_sitter);

    const rc_rope = addTestableModule(&bops, "src/buffer/RcRope.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    _ = rc_rope;

    const undo_tree = addTestableModule(&bops, "src/buffer/UndoTree.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    _ = undo_tree;

    _ = addTestableModule(&bops, "src/window/LinkedList.zig", &.{}, zig_build_test_step);

    /////////////////////////////

    const ropeman = addTestableModule(&bops, "src/buffer/RopeMan.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const buffer = addTestableModule(&bops, "src/buffer/Buffer.zig", &.{
        .{ .name = "RopeMan", .module = ropeman.module },
        .{ .name = "LangSuite", .module = langsuite.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const window_source = addTestableModule(&bops, "src/window/WindowSource.zig", &.{
        .{ .name = "Buffer", .module = buffer.module },
        .{ .name = "LangSuite", .module = langsuite.module },
    }, zig_build_test_step);
    _ = window_source;

    ////////////////////////////////////////////////////////////////////////////// Local Modules

    const input_processor = addTestableModule(&bops, "src/keyboard/input_processor.zig", &.{}, zig_build_test_step);

    const the_list = addTestableModule(&bops, "src/components/TheList.zig", &.{}, zig_build_test_step);

    _ = addTestableModule(&bops, "src/demos/write_struct_to_file.zig", &.{
        .{ .name = "s2s", .module = s2s },
    }, zig_build_test_step);

    _ = addTestableModule(&bops, "src/window/neo_cell.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    const rope = addTestableModule(&bops, "src/buffer/rope.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    _ = addTestableModule(&bops, "src/fs.zig", &.{}, zig_build_test_step);

    const ts_predicates = addTestableModule(&bops, "src/tree-sitter/predicates.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    ts_predicates.compile.linkLibrary(tree_sitter);

    const ts = addTestableModule(&bops, "src/tree-sitter/ts.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    ts.module.linkLibrary(tree_sitter);

    const neo_buffer = addTestableModule(&bops, "src/buffer/neo_buffer.zig", &.{
        .{ .name = "rope", .module = rope.module },
        .{ .name = "ts", .module = ts.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);

    const virtuous_window = addTestableModule(&bops, "src/window/virtuous_window.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        .{ .name = "input_processor", .module = input_processor.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);

    const display_cache_pool = addTestableModule(&bops, "src/window/DisplayCachePool.zig", &.{
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        .{ .name = "ts", .module = ts.module },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);

    const window_manager = addTestableModule(&bops, "src/window/window_manager.zig", &.{
        .{ .name = "ts", .module = ts.module },
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        .{ .name = "DisplayCachePool", .module = display_cache_pool.module },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);

    ////////////////////////////////////////////////////////////////////////////// Executable

    {
        const path = "src/window/TheSomething.zig";
        const exe = b.addExecutable(.{
            .name = "TheSomething",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("Buffer", buffer.module);
        exe.root_module.addImport("LangSuite", langsuite.module);
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.root_module.linkLibrary(ztracy.artifact("tracy"));
        addRunnableRaylibFile(b, exe, raylib, path);
    }

    ///////////////////////////// Raylib

    {
        const path = "src/style_parser_test.zig";
        const exe = b.addExecutable(.{
            .name = "style_parser_test",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.root_module.addImport("LangSuite", langsuite.module);
        exe.root_module.linkLibrary(ztracy.artifact("tracy"));
        addRunnableRaylibFile(b, exe, raylib, path);
    }

    // {
    //     const path = "src/window_test.zig";
    //     const exe = b.addExecutable(.{
    //         .name = "window_test",
    //         .root_source_file = b.path(path),
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     exe.root_module.addImport("window", window.module);
    //     exe.root_module.addImport("ztracy", ztracy.module("root"));
    //     exe.root_module.addImport("input_processor", input_processor.module);
    //     exe.root_module.linkLibrary(ztracy.artifact("tracy"));
    //     exe.root_module.addImport("ts", ts.module);
    //     addRunnableRaylibFile(b, exe, raylib, path);
    //
    //     b.installArtifact(exe);
    // }

    {
        const path = "src/new_mapping_methods.zig";
        const exe = b.addExecutable(.{
            .name = "new_mapping_methods",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("input_processor", input_processor.module);
        exe.root_module.addImport("window_manager", window_manager.module);
        exe.root_module.addImport("TheList", the_list.module);
        exe.root_module.addImport("virtuous_window", virtuous_window.module);
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(tree_sitter);
        exe.linkLibrary(ztracy.artifact("tracy"));
        addRunnableRaylibFile(b, exe, raylib, path);
    }

    {
        const path = "src/demos/spawn_rec_by_clicking.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "spawn_rec_by_clicking",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }

    {
        const path = "src/demos/camera2d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "camera2d_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/drag_camera_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "drag_camera_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/camera3d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "camera3d_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/demos/bunnymark.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "bunnymark",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }

    {
        const exe = b.addExecutable(.{
            .name = "main",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("input_processor", input_processor.module);
        exe.root_module.addImport("neo_buffer", neo_buffer.module);
        exe.root_module.addImport("virtuous_window", virtuous_window.module);
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(tree_sitter);
        exe.linkLibrary(ztracy.artifact("tracy"));

        exe.linkLibrary(raylib.artifact("raylib"));
        exe.root_module.addImport("raylib", raylib.module("raylib"));

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step("run", "Run Application");
        run_step.dependOn(&run_cmd.step);
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
