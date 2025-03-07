/// Micro benchmarks that might indicate some characteristics of an allocator.
///
/// These tests should idealy not run longer than 1 second, and should somewhat
/// atomically show a potentially interesting feature about an allocator.
///
/// These tests may only be interesting when doing a profiling run.
pub const micro = [_]TestInformation{
    // NOTE: These tests ought to define rerun to minimize the time they take to run.

    // Nano benchmarks that very quickly give mildy interesting data
    .{
        .name = "First allocation",
        .description =
        \\ The very first allocation of differing sizes after the initialization
        \\ of the allocator
        \\
        ,
        .charactaristics = .default,
        .test_fn = &firstAlloc,
        .timeout_ns = std.time.ns_per_s,
        .rerun = .{
            .run_at_least = 50,
            .run_for_ns = std.time.ns_per_ms,
        },
    },

    // Microbenchmarks on the allocator interface
    .{
        .name = "Many allocations",
        .description =
        \\ To observe allocation speed, we do many allocations. Keeping up to 10
        \\ in memory. The size of allocations is uniform between [1, arg].
        \\
        ,
        .test_fn = &manyAllocations,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .timeout_ns = std.time.ns_per_s * 5,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 5,
        },
    },
    .{
        .name = "Many resizes",
        .description =
        \\ To observe resize speed, we do many resizes. First creating 100 
        \\ allocations and then continuously resizing them. The new size of the
        \\ resizes is uniformly between [1, arg]. 
        \\
        \\ NOTE: many resizes may be rejected, leading to artificially good
        \\ numbers. A profiling run will reveal this.
        \\
        ,
        .test_fn = &manyResizes,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .timeout_ns = std.time.ns_per_s * 5,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 5,
        },
    },
    .{
        .name = "Many remaps",
        .description =
        \\ To observe remap speed, we do many remaps. First creating 100 
        \\ allocations and then continuously remapping them. The new size of the
        \\ remaps is uniformly between [1, arg]. 
        \\
        \\ NOTE: many remaps may be rejected, leading to artificially good
        \\ numbers. A profiling run will reveal this.
        \\
        ,
        .test_fn = &manyRemaps,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .timeout_ns = std.time.ns_per_s * 5,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 5,
        },
    },

    // Other
    .{
        .name = "Binned allocations",
        .description =
        \\ Many allocators have power of 2 bin sizes in which they allocate blocks.
        \\ This microbenchmark shows the speed of different bins, by allocating
        \\ blocks between [arg / 2, arg] in size, keeping up to 10 in memory.
        \\ 
        ,
        .test_fn = &allocBins,
        .timeout_ns = std.time.ns_per_s / 5,
        .arg = .{ .exponential = .{ .start = 64, .n = 15 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
};

fn firstAlloc(alloc: Allocator, size: ArgInt) !void {
    const a = try alloc.alloc(u8, size);
    defer alloc.free(a);
}

fn manyAllocations(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    var data: [10][]u8 = undefined;
    for (&data) |*e| e.* = try allocRange(u8, rand, alloc, 1, arg);
    defer for (data) |e| alloc.free(e);

    for (0..10_000) |_| {
        const idx = rand.intRangeLessThan(usize, 0, data.len);

        alloc.free(data[idx]);

        data[idx] = try allocRange(u8, rand, alloc, 1, arg);
        touchAllocation(rand, data[idx]);
    }
}

fn manyResizes(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    var data: [100][]u8 = undefined;
    for (&data) |*e| e.* = try allocRange(u8, rand, alloc, 1, arg);
    defer for (data) |e| alloc.free(e);

    for (0..10_000) |_| {
        const idx = rand.intRangeLessThan(usize, 0, data.len);

        const new_len = rand.intRangeAtMost(usize, 1, arg);
        if (alloc.resize(data[idx], new_len)) {
            data[idx].len = new_len;

            touchAllocation(rand, data[idx]);
        }
    }
}

fn manyRemaps(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    var data: [100][]u8 = undefined;
    for (&data) |*e| e.* = try allocRange(u8, rand, alloc, 1, arg);
    defer for (data) |e| alloc.free(e);

    for (0..10_000) |_| {
        const idx = rand.intRangeLessThan(usize, 0, data.len);

        const new_len = rand.intRangeAtMost(usize, 1, arg);
        data[idx] = alloc.remap(data[idx], new_len) orelse data[idx];
        touchAllocation(rand, data[idx]);
    }
}

fn allocBins(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    const max = arg;
    const min = arg >> 1;

    assert(min > 0);

    var data: [10][]u8 = undefined;
    for (&data) |*e| e.* = try allocRange(u8, rand, alloc, min, max);
    defer for (data) |e| alloc.free(e);

    for (0..100) |_| {
        const idx = rand.intRangeLessThan(usize, 0, data.len);

        alloc.free(data[idx]);

        data[idx] = try allocRange(u8, rand, alloc, min, max);
        touchAllocation(rand, data[idx]);
    }
}

const std = @import("std");
const runner = @import("runner");
const common = @import("common.zig");
const playback = @import("playback.zig");
const mimalloc_bench = @import("mimalloc-bench.zig");

const assert = std.debug.assert;
const allocRange = common.allocRange;
const touchAllocation = common.touchAllocation;

const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Random = std.Random;
const Alignment = std.mem.Alignment;
const Thread = std.Thread;
