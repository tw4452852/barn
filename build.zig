const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    if (comptime !checkVersion())
        @compileError("Old compiler!");

    const exe = b.addExecutable("barn", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.addIncludeDir("vendor/include");
    exe.addIncludeDir("vendor/libfuse/include");

    const libfuse = b.addStaticLibrary("libfuse", null);
    libfuse.addIncludeDir("vendor/include");
    libfuse.addIncludeDir("vendor/libfuse/include");
    libfuse.setTarget(target);
    libfuse.setBuildMode(mode);
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
    const libfuseFlags = [_][]const u8{
        "-DFUSE_USE_VERSION=35",
    };
    libfuse.addCSourceFiles(&libfuseSources, &libfuseFlags);
    exe.linkLibrary(libfuse);

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);
    exe_tests.linkLibC();
    exe_tests.addIncludeDir("vendor/include");
    exe_tests.addIncludeDir("vendor/libfuse/include");
    exe_tests.linkLibrary(libfuse);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

// ziglings reference
fn checkVersion() bool {
    if (!@hasDecl(builtin, "zig_version")) {
        return false;
    }

    const needed_version = std.SemanticVersion.parse("0.10.0-dev.3685") catch unreachable;
    const version = builtin.zig_version;
    const order = version.order(needed_version);
    return order != .lt;
}
