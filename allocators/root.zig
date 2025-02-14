pub const default: []const ContructorInformation = &.{
    .{
        .name = "Debug allocator",
        .characteristics = .default,
        .constr_fn = &simpleGpa,
    },
    .{
        .name = "SMP allocator",
        .characteristics = .default,
        .constr_fn = &smpAlloc,
    },
};

fn simpleGpa(opts: runner.TestOpts) !?Profiling {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn smpAlloc(opts: runner.TestOpts) !?Profiling {
    const smp = std.heap.smp_allocator;

    return runner.run(smp, opts);
}

const std = @import("std");
const runner = @import("runner");
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;
