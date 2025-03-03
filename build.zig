pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});

    const native_target = b.resolveTargetQuery(.{});

    const optimize: OptimizeMode = switch (b.release_mode) {
        .off => .Debug,
        .any => .ReleaseSafe,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };

    const selfhosted = b.option(bool, "selfhosted", "Use the selfhosted compiler") orelse false;
    const external = b.option(bool, "external", "Link in external allocators") orelse true;
    const use_libc = b.option(bool, "useLibc", "Link in external allocators") orelse true;

    const runner_mod = runner(b, target, optimize);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = use_libc,
    });
    exe_mod.addImport("runner", runner_mod);
    exe_mod.addImport("tests", tests(b, runner_mod, target, optimize));

    const opts = b.addOptions();

    const can_link_externals = use_libc and external and isExternalsInstalled() and
        target.result.dynamic_linker.eql(native_target.result.dynamic_linker);

    const constr_mod = constructors(b, use_libc, runner_mod, target, optimize);

    // Add externals
    opts.addOption(bool, "use_libc", use_libc);
    opts.addOption(bool, "jemalloc", can_link_externals);
    opts.addOption(bool, "mimalloc", can_link_externals);

    constr_mod.addOptions("config", opts);
    if (can_link_externals) {
        std.log.info("Adding jemalloc", .{});
        constr_mod.addImport("jemalloc", jemalloc(b, target, optimize));

        std.log.info("Adding mimalloc", .{});
        constr_mod.addImport("mimalloc", mimalloc(b, target, optimize));
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

    installExternalsStep(b, native_target);
}

fn installExternalsStep(b: *Build, target: Build.ResolvedTarget) void {
    const install_step = b.step("externals", "Install external allocators (requires nix)");

    const install_mod = b.createModule(.{
        .root_source_file = b.path("externals.zig"),
        .target = target,
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

pub fn constructors(b: *Build, use_libc: bool, runner_mod: *Module, target: Build.ResolvedTarget, optimize: OptimizeMode) *Module {
    const rpmalloc = b.dependency("rpmalloc", .{
        .target = target,
        .optimize = optimize,
    });

    const constructors_mod = b.createModule(.{
        .root_source_file = b.path("constructors/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = use_libc,
    });
    constructors_mod.addImport("runner", runner_mod);

    if (use_libc) {
        constructors_mod.addImport("rpmalloc", rpmalloc.module("bindings"));
    }

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
