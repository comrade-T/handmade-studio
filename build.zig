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

    _ = addTestableModule(&bops, "src/keyboard/state.zig", &.{
        .{ .name = "raylib", .module = raylib.module("raylib") },
    }, zig_build_test_step);

    const buffer = addTestableModule(&bops, "src/buffer/buffer.zig", &.{
        .{ .name = "code_point", .module = zg.module("code_point") },
    }, zig_build_test_step);

    _ = addTestableModule(&bops, "src/buffer/cursor.zig", &.{}, zig_build_test_step);

    const ts = addTestableModule(&bops, "src/tree-sitter/ts.zig", &.{}, zig_build_test_step);
    ts.compile.linkLibrary(tree_sitter);

    ////////////////////////////////////////////////////////////////////////////// Executable

    {
        const exe = b.addExecutable(.{
            .name = "communism",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.linkLibrary(raylib.artifact("raylib"));
        exe.root_module.addImport("raylib", raylib.module("raylib"));

        exe.root_module.addImport("buffer", buffer.module);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run Communism Studio");
        run_step.dependOn(&run_cmd.step);
    }
}

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
