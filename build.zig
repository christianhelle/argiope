const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addArgiopeExecutable(b, target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run argiope");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    addInstallStep(b, target, "install-release", "Build ReleaseSmall and install to $HOME/.local/bin", .ReleaseSmall);
    addInstallStep(b, target, "install-release-safe", "Build ReleaseSafe and install to $HOME/.local/bin", .ReleaseSafe);
    addInstallStep(b, target, "install-release-fast", "Build ReleaseFast and install to $HOME/.local/bin", .ReleaseFast);
    addInstallStep(b, target, "install-debug", "Build Debug and install to $HOME/.local/bin", .Debug);
}

fn addArgiopeExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "argiope",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("images/icon.rc") });
    }
    return exe;
}

fn addInstallStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    step_name: []const u8,
    description: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = addArgiopeExecutable(b, target, optimize);
    const installer = b.addExecutable(.{
        .name = "install_release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/install_release.zig"),
            .target = b.graph.host,
        }),
    });

    const install = b.addRunArtifact(installer);
    install.setName(b.fmt("install {s} ({s})", .{ exe.out_filename, @tagName(optimize) }));
    install.has_side_effects = true;
    install.addFileArg(exe.getEmittedBin());
    install.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    install.addDirectoryArg2(b.path("zig-out"), .{ .make_absolute = true });
    install.addArg(exe.out_filename);

    const install_step = b.step(step_name, description);
    install_step.dependOn(&install.step);
}
