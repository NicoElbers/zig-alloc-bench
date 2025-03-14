/// Benchmarks that might indicate some characteristics of an allocator.
pub const bench = [_]TestInformation{
    .{
        .name = "xmalloc",
        .description =
        \\ N producer and N consumer threads operating on batches of 4096 
        \\ randomly sized allocations (so 2N threads), where N is the argument.
        \\ Producers exclusively allocate and consumers exclusively free,
        \\ passing batches through a single (blocking) list.
        \\
        ,
        .charactaristics = .{
            .multithreaded = true,
        },
        .test_fn = &xmalloc,
        .timeout_ns = std.time.ns_per_s * 2,
        .arg = .{ .exponential = .{ .start = 1, .n = 5 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 5,
        },
    },
};

fn xmalloc(alloc: Allocator, workers: ArgInt) !void {
    const run = @import("xmalloc-test/xmalloc-test.zig").run;

    try run(alloc, .{
        .batches = 4096,
        .limit = 1000,
        .workers = workers,
    });
}

const std = @import("std");
const runner = @import("runner");

const getCpuCount = Thread.getCpuCount;

const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Thread = std.Thread;
