const std = @import("std");
const original_build_file = @import("build.zig");

pub fn build(b: *std.Build) void {
    buildOriginalBuildGraph(b);
    addNeotestBuildStep(b);
    passArguments(b);
    replaceTestRunner(b);
}

/// Builds original graph from user's `build.zig` file.
fn buildOriginalBuildGraph(b: *std.Build) void {
    const can_build_function_return_error = @typeInfo(@typeInfo(@TypeOf(original_build_file.build)).@"fn".return_type.?) == .error_union;
    if (can_build_function_return_error) {
        original_build_file.build(b) catch |err| {
            std.log.err("Function `build` from `build.zig` returned an error: {}", .{err});
            std.process.exit(1);
        };
    } else {
        original_build_file.build(b);
    }
}

/// Adds a step to build test binaries without running them.
/// Used for launching a debuger.https://codeberg.org/ziglings/exercises.git
fn addNeotestBuildStep(b: *std.Build) void {
    const neotest_build_step = b.step("neotest-build", "Build tests without running");
    const test_step = getTestStep(b);
    for (test_step.dependencies.items) |maybe_test_step_run| {
        if (maybe_test_step_run.cast(std.Build.Step.Run) == null) {
            // Not interested in non-run steps here.
            continue;
        }
        for (maybe_test_step_run.dependencies.items) |maybe_compile_step| {
            const test_step_compile = maybe_compile_step.cast(std.Build.Step.Compile) orelse continue;
            const install_test = b.addInstallArtifact(test_step_compile, .{
                // TODO: Handle empty names.
                // If empty or default, then suggest renaming addTest compile step in build.zig for the user.
                // This could be extracted the same way as multiple choices will be with the neotest-dry-run step.
                .dest_sub_path = std.fmt.allocPrint(b.allocator, "../test/{s}", .{test_step_compile.name}) catch unreachable,
            });
            neotest_build_step.dependOn(&install_test.step);
        }
    }
}

/// Adds arguments to test run steps.
/// For example `--neotest-results-path`.
fn passArguments(b: *std.Build) void {
    const build_args = b.args orelse return;
    const test_step = getTestStep(b);
    for (test_step.dependencies.items) |substep| {
        const test_step_run = substep.cast(std.Build.Step.Run) orelse continue;
        test_step_run.addArgs(build_args);
    }
}

/// Replaces default test runner with a custom neotest runner, which uses
/// exact test filtering via input files and provides test results via output files.
fn replaceTestRunner(b: *std.Build) void {
    const test_step = getTestStep(b);
    const test_runner = b.option([]const u8, "neotest-runner", "Use a custom test runner");
    for (test_step.dependencies.items) |maybe_test_step_run| {
        if (maybe_test_step_run.cast(std.Build.Step.Run) == null) {
            // Not interested in non-run steps here.
            continue;
        }
        for (maybe_test_step_run.dependencies.items) |maybe_test_step_compile| {
            const test_step_compile = maybe_test_step_compile.cast(std.Build.Step.Compile) orelse continue;
            test_step_compile.test_runner = if (test_runner) |x| .{ .cwd_relative = x } else null;
        }
    }
}

inline fn getTestStep(b: *const std.Build) *std.Build.Step {
    if (b.top_level_steps.get("test")) |test_step| {
        return &test_step.step;
    } else {
        @panic("Neotest runner requires a 'test' step to be defined in `build.zig`.");
    }
}
