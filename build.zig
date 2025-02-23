pub fn build(b: *Build) void {
    const Libc = enum { musl, system };
    const libc = b.option(Libc, "libc", "Choose the libc version linked (requires installed externals)") orelse .musl;

    const x86_v3 = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .abi = switch (libc) {
            .musl => .musl,
            .system => null,
        },
    });
    const optimize: OptimizeMode = switch (b.release_mode) {
        .off => .Debug,
        .any => .ReleaseSafe,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    const selfhosted = b.option(bool, "selfhosted", "Use the selfhosted compiler") orelse false;

    const runner_mod = runner(b, x86_v3, optimize);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = x86_v3,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("runner", runner_mod);
    exe_mod.addImport("tests", tests(b, runner_mod, x86_v3, optimize));
    exe_mod.addImport("constructors", constructors(b, runner_mod, x86_v3, optimize));

    const exe = b.addExecutable(.{
        .name = "alloc-bench",
        .root_module = exe_mod,
        .use_llvm = !selfhosted,
        .use_lld = !selfhosted,
    });

    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

pub fn runner(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    return b.createModule(.{
        .root_source_file = b.path("src/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn tests(b: *Build, runner_mod: *Module, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("runner", runner_mod);

    return tests_mod;
}

pub fn constructors(b: *Build, runner_mod: *Module, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    const rpmalloc = b.dependency("rpmalloc", .{
        .target = target,
        .optimize = optimize,
    });

    const constructors_mod = b.createModule(.{
        .root_source_file = b.path("constructors/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    constructors_mod.addImport("rpmalloc", rpmalloc.module("bindings"));
    constructors_mod.addImport("runner", runner_mod);

    return constructors_mod;
}

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.os.tag;

const OptimizeMode = std.builtin.OptimizeMode;
const Build = std.Build;
const Module = std.Build.Module;
