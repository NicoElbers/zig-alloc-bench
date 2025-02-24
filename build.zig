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

    const opts = b.addOptions();

    const constr_mod = constructors(b, runner_mod, x86_v3, optimize);
    opts.addOption(bool, "jemalloc", isExternalsInstalled());
    opts.addOption(bool, "mimalloc", isExternalsInstalled());

    constr_mod.addOptions("config", opts);

    if (isExternalsInstalled()) {
        std.log.info("Adding jemalloc", .{});
        constr_mod.addImport("jemalloc", jemalloc(b, x86_v3, optimize));

        std.log.info("Adding mimalloc", .{});
        constr_mod.addImport("mimalloc", mimalloc(b, x86_v3, optimize));
    }
    exe_mod.addImport("constructors", constr_mod);

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

    installExternalsStep(b);
}

fn installExternalsStep(b: *Build) void {
    const install_step = b.step("externals", "Install external allocators (requires nix)");

    const install_mod = b.createModule(.{
        .root_source_file = b.path("externals.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = .Debug, // Faster builds
    });

    const exe = b.addExecutable(.{
        .name = "install_externals",
        .root_module = install_mod,
        .use_llvm = false,
        .use_lld = false,
    });

    const run = b.addRunArtifact(exe);

    install_step.dependOn(&run.step);
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

pub fn jemalloc(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    assert(isExternalsInstalled());

    const jemalloc_mod = b.createModule(.{
        .root_source_file = b.path("external_allocators/jemalloc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    jemalloc_mod.addLibraryPath(b.path("external/jemalloc"));
    jemalloc_mod.linkSystemLibrary("jemalloc", .{
        .needed = true,
        .preferred_link_mode = .dynamic,
    });

    jemalloc_mod.addIncludePath(b.path("external/jemalloc/include"));

    return jemalloc_mod;
}

pub fn mimalloc(b: *Build, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    assert(isExternalsInstalled());

    const mimalloc_mod = b.createModule(.{
        .root_source_file = b.path("external_allocators/mimalloc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mimalloc_mod.addLibraryPath(b.path("external/mimalloc"));
    mimalloc_mod.linkSystemLibrary("mimalloc", .{
        .needed = true,
        .preferred_link_mode = .dynamic,
    });

    mimalloc_mod.addIncludePath(b.path("external/mimalloc/include"));

    return mimalloc_mod;
}

fn isExternalsInstalled() bool {
    std.fs.cwd().accessZ("external", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => @panic("Fs error"),
    };
    return true;
}

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.os.tag;
const assert = std.debug.assert;

const OptimizeMode = std.builtin.OptimizeMode;
const Build = std.Build;
const Module = std.Build.Module;
