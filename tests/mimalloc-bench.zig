pub const mimalloc_bench = [_]TestInformation{
    .{
        .name = "cache scratch 1",
        .test_fn = &cacheScratch1,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 20 * 999,
        .arg = .{ .list = &.{ 1, 1 << 3, 1 << 5 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 10,
        },
    },
    .{
        .name = "cache scratch N",
        .test_fn = &cacheScratchN,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 20 * 999,
        .arg = .{ .list = &.{ 1, 1 << 3, 1 << 5 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 10,
        },
    },
};

fn cacheScratch1(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("mimalloc-bench/cache-scratch/cache-scratch.zig").run;

    const cpu = std.Thread.getCpuCount() catch 1;

    try run(alloc, .{
        .thread_count = 1,
        .iterations = 1_000,
        .obj_size = @truncate(arg),
        .repetitions = 2_000_000,
        .concurrency = cpu,
    });
}

fn cacheScratchN(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("mimalloc-bench/cache-scratch/cache-scratch.zig").run;

    const cpu = std.Thread.getCpuCount() catch 1;

    try run(alloc, .{
        .thread_count = cpu,
        .iterations = 1_000,
        .obj_size = @truncate(arg),
        .repetitions = 2_000_000,
        .concurrency = cpu,
    });
}

const std = @import("std");
const runner = @import("runner");

const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Allocator = std.mem.Allocator;
