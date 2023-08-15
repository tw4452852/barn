const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "barn",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.linkLibC();
    exe.addIncludePath(.{ .path = "vendor/include" });
    exe.addIncludePath(.{ .path = "vendor/libfuse/include" });

    const libfuse = b.addStaticLibrary(.{
        .name = "libfuse",
        .target = target,
        .optimize = mode,
    });
    libfuse.addIncludePath(.{ .path = "vendor/include" });
    libfuse.addIncludePath(.{ .path = "vendor/libfuse/include" });
    libfuse.omit_frame_pointer = false;
    libfuse.linkLibC();
    const libfuseSources = [_][]const u8{
        "vendor/libfuse/lib/fuse.c",
        "vendor/libfuse/lib/fuse_i.h",
        "vendor/libfuse/lib/fuse_loop.c",
        "vendor/libfuse/lib/fuse_loop_mt.c",
        "vendor/libfuse/lib/fuse_lowlevel.c",
        "vendor/libfuse/lib/fuse_misc.h",
        "vendor/libfuse/lib/fuse_opt.c",
        "vendor/libfuse/lib/fuse_signals.c",
        "vendor/libfuse/lib/buffer.c",
        "vendor/libfuse/lib/cuse_lowlevel.c",
        "vendor/libfuse/lib/helper.c",
        "vendor/libfuse/lib/modules/subdir.c",
        "vendor/libfuse/lib/mount_util.c",
        "vendor/libfuse/lib/fuse_log.c",
        "vendor/libfuse/lib/mount.c",
    };
    libfuse.defineCMacro("FUSE_USE_VERSION", "35");
    libfuse.addCSourceFiles(&libfuseSources, &.{
        "-Wall",
        "-Wextra",
        // "-Wpedantic",
    });
    exe.linkLibrary(libfuse);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .name = "barn-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe_tests.addIncludePath(.{ .path = "vendor/include" });
    exe_tests.addIncludePath(.{ .path = "vendor/libfuse/include" });
    exe_tests.linkLibrary(libfuse);
    exe_tests.linkLibC();

    const install_test = b.addInstallArtifact(exe_tests, .{});
    const test_step = b.step("test", "Build unit tests");
    test_step.dependOn(&install_test.step);
}
