const std = @import("std");

pub fn build(b: *std.Build) void {
    const game_only = b.option(bool, "game_only", "only build the game shared library") orelse false;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    ////////////////////////////////////////////////////////////////////////////// Dependencies

    // const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });

    ////////////////////////////////////////////////////////////////////////////// Game

    {
        const game_lib = b.addSharedLibrary(.{
            .name = "game",
            .root_source_file = b.path("src/game.zig"),
            .target = target,
            .optimize = optimize,
        });

        // game_lib.root_module.addImport("pretty", pretty.module("pretty"));

        game_lib.linkSystemLibrary("raylib");
        game_lib.linkLibC();
        b.installArtifact(game_lib);
    }

    // Exe
    if (!game_only) {
        const exe = b.addExecutable(.{
            .name = "communism",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.linkSystemLibrary("raylib");
        exe.linkLibC();
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
