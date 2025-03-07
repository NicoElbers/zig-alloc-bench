pub const tests = [_]TestInformation{
    // Cache
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

    // glibc
    .{
        .name = "glibc Main arena",
        .test_fn = &glibcMainArena,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 15,
        .arg = .{ .exponential = .{ .start = 16, .n = 2 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 10,
        },
    },
    .{
        .name = "glibc Threaded",
        .test_fn = &glibcThreaded,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 15,
        .arg = .{ .exponential = .{ .start = 16, .n = 2 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 10,
        },
    },
    .{
        .name = "glibc Main arena with thread",
        .test_fn = &glibcMainArenaThreaded,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 15,
        .arg = .{ .exponential = .{ .start = 16, .n = 2 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 10,
        },
    },

    // mstress
    .{
        .name = "mstress",
        .test_fn = &mstress,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 15 * 30,
        // .arg = .{ .exponential = .{ .start = 16, .n = 2 } },
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

fn glibcMainArena(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("mimalloc-bench/glibc-bench/bench-malloc-simple.zig").benchMainArena;

    try run(alloc, arg);
}

fn glibcThreaded(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("mimalloc-bench/glibc-bench/bench-malloc-simple.zig").benchThreaded;

    try run(alloc, arg);
}

fn glibcMainArenaThreaded(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("mimalloc-bench/glibc-bench/bench-malloc-simple.zig").benchMainWithThread;

    try run(alloc, arg);
}

fn mstress(alloc: Allocator, arg: ArgInt) !void {
    _ = arg;

    const run = @import("mimalloc-bench/mstress/mstress.zig").run;

    const cpu = std.Thread.getCpuCount() catch 1;

    try run(alloc, .{
        .thread_count = cpu,
        .scale = 50,
        .iter = 100,
        .transfer_count = 1000,
    });
}

const std = @import("std");
const runner = @import("runner");

const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Allocator = std.mem.Allocator;
