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

    const logz = b.dependency("logz", .{ .target = target, .optimize = optimize });

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

    ////////////////////////////////////////////////////////////////////////////// Local Modules

    _ = addTestableModule(&bops, "src/buffer/write_struct_to_file.zig", &.{
        .{ .name = "s2s", .module = s2s },
    }, zig_build_test_step);

    _ = addTestableModule(&bops, "src/keyboard/state.zig", &.{
        .{ .name = "raylib", .module = raylib.module("raylib") },
    }, zig_build_test_step);

    const buffer = addTestableModule(&bops, "src/buffer/buffer.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    const rope = addTestableModule(&bops, "src/buffer/rope.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    _ = addTestableModule(&bops, "src/window/ugly_textbox.zig", &.{
        .{ .name = "rope", .module = rope.module },
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    const cursor = addTestableModule(&bops, "src/window/cursor.zig", &.{}, zig_build_test_step);

    _ = addTestableModule(&bops, "src/fs.zig", &.{}, zig_build_test_step);

    const ts = addTestableModule(&bops, "src/tree-sitter/ts.zig", &.{
        .{ .name = "regex", .module = regex },
        .{ .name = "ztracy", .module = ztracy.module("root") },
    }, zig_build_test_step);
    ts.compile.linkLibrary(tree_sitter);
    ts.compile.linkLibrary(ztracy.artifact("tracy"));

    const neo_buffer = addTestableModule(&bops, "src/buffer/neo_buffer.zig", &.{
        .{ .name = "rope", .module = rope.module },
        .{ .name = "ts", .module = ts.module },
    }, zig_build_test_step);
    neo_buffer.compile.linkLibrary(tree_sitter);

    const content_vendor = addTestableModule(&bops, "src/window/content_vendor.zig", &.{
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        .{ .name = "ztracy", .module = ztracy.module("root") },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    content_vendor.compile.linkLibrary(tree_sitter);
    content_vendor.compile.linkLibrary(ztracy.artifact("tracy"));

    const neo_window = addTestableModule(&bops, "src/window/neo_window.zig", &.{
        .{ .name = "cursor", .module = cursor.module },
        .{ .name = "content_vendor", .module = content_vendor.module },
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    neo_window.compile.linkLibrary(tree_sitter);

    const ugly_window = addTestableModule(&bops, "src/window/ugly_window.zig", &.{
        .{ .name = "neo_buffer", .module = neo_buffer.module },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    ugly_window.compile.linkLibrary(tree_sitter);

    _ = addTestableModule(&bops, "src/window/neo_cell.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    const window_backend = addTestableModule(&bops, "src/window/backend.zig", &.{
        .{ .name = "buffer", .module = buffer.module },
        .{ .name = "ts", .module = ts.module },
        .{ .name = "raylib", .module = raylib.module("raylib") },
        ts_queryfile(b, "submodules/tree-sitter-zig/queries/highlights.scm"),
    }, zig_build_test_step);
    window_backend.compile.linkLibrary(tree_sitter);

    ////////////////////////////////////////////////////////////////////////////// Executable

    {
        const exe = b.addExecutable(.{
            .name = "profile_content_vendor",
            .root_source_file = b.path("src/window/content_vendor_profiling.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(ztracy.artifact("tracy"));

        ///////////////////////////// Local Modules

        exe.root_module.addImport("neo_buffer", neo_buffer.module);
        exe.root_module.addImport("content_vendor", content_vendor.module);
        exe.root_module.addImport("neo_window", neo_window.module);
        exe.linkLibrary(tree_sitter);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        const run_step = b.step("profile", "profile_content_vendor");
        run_step.dependOn(&run_cmd.step);
    }

    ///////////////////////////// Raylib

    {
        const path = "src/spawn_rec_by_clicking.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "spawn_rec_by_clicking",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }

    {
        const path = "src/camera2d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "camera2d_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/drag_camera_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "drag_camera_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/camera3d_example.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "camera3d_example",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }
    {
        const path = "src/bunnymark.zig";
        const spawn_rec_by_clicking_exe = b.addExecutable(.{
            .name = "bunnymark",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        addRunnableRaylibFile(b, spawn_rec_by_clicking_exe, raylib, path);
    }

    {
        const path = "src/spawn_text_box_by_clicking.zig";
        const spawn_text = b.addExecutable(.{
            .name = "spawn_text_box_by_clicking",
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        spawn_text.root_module.addImport("neo_buffer", neo_buffer.module);
        spawn_text.root_module.addImport("content_vendor", content_vendor.module);
        spawn_text.root_module.addImport("neo_window", neo_window.module);
        spawn_text.root_module.addImport("ztracy", ztracy.module("root"));
        spawn_text.linkLibrary(tree_sitter);
        spawn_text.linkLibrary(ztracy.artifact("tracy"));
        addRunnableRaylibFile(b, spawn_text, raylib, path);
    }

    {
        const exe = b.addExecutable(.{
            .name = "communism",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.linkLibrary(raylib.artifact("raylib"));
        exe.root_module.addImport("raylib", raylib.module("raylib"));
        exe.root_module.addImport("window_backend", window_backend.module);

        exe.root_module.addImport("logz", logz.module("logz"));

        exe.linkLibrary(tree_sitter);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run Communism Studio");
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
