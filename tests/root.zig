pub const default = correctness ++ [_]TestInformation{
    .{
        .name = "First allocation",
        .test_fn = &firstAlloc,
        .arg = .{ .exponential = .{ .n = 20 } },
        .rerun = .{
            .run_at_least = 50,
            .run_for_ns = 0,
        },
    },
    .{
        .name = "Binned allocations",
        .test_fn = &allocBins,
        .timeout_ns = std.time.ns_per_s / 10,
        .arg = .{ .exponential = .{ .start = 64, .n = 14 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Many allocations and frees",
        .test_fn = &manyAllocFree,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Many allocations, resizes and frees",
        .test_fn = &manyAllocResizeFree,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Many allocations, remaps and frees",
        .test_fn = &manyAllocRemapsFree,
        .timeout_ns = std.time.ns_per_s * 2,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Appending to many arraylists",
        .test_fn = &appendingToMultipleArrayLists,
        .arg = .{ .exponential = .{ .start = 1, .n = 10 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Random access append",
        .test_fn = &appendAccessArray,
        .arg = .{ .exponential = .{ .start = 1024, .n = 5 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s / 10,
        },
    },
    .{
        .name = "Evicting array",
        .test_fn = &evictingArray,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
        },
        .timeout_ns = std.time.ns_per_s * 5,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 5,
        },
        .arg = .{ .exponential = .{ .start = 1, .n = 5 } },
    },
} ++ mimalloc_bench.tests ++ playback.tests;

pub const correctness = [_]TestInformation{
    .{
        .name = "std tests",
        .test_fn = &stdTests,
        .charactaristics = .{
            .testing = true,
        },
    },
    .{
        .name = "Page alignment",
        .charactaristics = .{
            .testing = true,
        },
        .test_fn = &pageAlign,
    },
    .{
        .name = "Failing test",
        .description =
        \\ A meta test that always fails with the error `error.Fail`
        \\ leading to a `genericError` in status detection
        ,
        .charactaristics = .{
            .meta = true,
            .failure = .any_failure,
            .testing = true,
        },
        .test_fn = &failingTest,
    },
    .{
        .name = "No free",
        .charactaristics = .{
            .failure = .any_failure,
            .testing = true,
        },
        .test_fn = &noFree,
    },
    .{
        .name = "Double free",
        .charactaristics = .{
            .failure = .any_failure,
            .testing = true,
        },
        .test_fn = &doubleFree,
    },
};

fn stdTests(alloc: Allocator, _: ArgInt) !void {
    try std.heap.testAllocator(alloc);
    try std.heap.testAllocatorAligned(alloc);
    try std.heap.testAllocatorLargeAlignment(alloc);
    try std.heap.testAllocatorAlignedShrink(alloc);
}

fn firstAlloc(alloc: Allocator, arg: ArgInt) !void {
    const a = try alloc.alloc(u8, arg);
    defer alloc.free(a);
}

fn allocBins(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    const max = arg;
    const min = arg >> 1;

    assert(min > 0);

    for (0..100) |_| {
        const arr = try allocRange(u8, rand, alloc, min, max);

        assert(arr.len <= max);
        assert(arr.len >= min);

        alloc.free(arr);
    }
}

fn manyAllocFree(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        const arr = try allocRange(u8, rand, alloc, 1, arg);
        alloc.free(arr);
    }
}

fn manyAllocResizeFree(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        var arr = try allocRange(u8, rand, alloc, 1, arg);
        touchAllocation(rand, arr);

        const new_len = rand.intRangeAtMost(usize, 1, arg);
        if (alloc.resize(arr, new_len)) arr.len = new_len;

        touchAllocation(rand, arr);

        alloc.free(arr);
    }
}

fn manyAllocRemapsFree(alloc: Allocator, arg: ArgInt) !void {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        const arr = try allocRange(u8, rand, alloc, 1, arg);

        touchAllocation(rand, arr);

        const new_len = rand.intRangeAtMost(usize, 1, arg);
        const arr2 = alloc.remap(arr, new_len) orelse blk: {
            defer alloc.free(arr);

            // remap indicated that alloc, copy, free is faster

            const arr2 = try alloc.alloc(u8, new_len);

            const min_len = @min(arr2.len, arr.len);

            @memcpy(arr2[0..min_len], arr[0..min_len]);
            break :blk arr2;
        };

        // Touch the new part of the buffer
        if (arr2.len > arr.len)
            touchAllocation(rand, arr2[arr.len..]);

        alloc.free(arr2);
    }
}

fn appendingToMultipleArrayLists(alloc: Allocator, arg: ArgInt) !void {
    var arrs = try alloc.alloc(std.ArrayListUnmanaged(ArgInt), arg);
    defer alloc.free(arrs);

    @memset(arrs, .empty);
    defer for (arrs) |*arr| arr.deinit(alloc);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        const idx = rand.intRangeAtMost(u64, 0, arrs.len - 1);
        try arrs[idx].append(alloc, rand.int(u64));
    }
}

fn appendAccessArray(alloc: Allocator, arg: ArgInt) !void {
    const Action = enum { append, access };

    var arr: std.ArrayListUnmanaged(u64) = .empty;
    defer arr.deinit(alloc);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    try arr.append(alloc, 0xdeadbeef);

    for (0..arg) |_| {
        switch (rand.enumValue(Action)) {
            .access => {
                const arr_idx = rand.intRangeAtMost(u64, 0, arr.items.len - 1);
                arr.items[arr_idx] = rand.int(u64);
            },
            .append => try arr.append(alloc, rand.int(u64)),
        }
    }
}

fn oomTest(alloc: Allocator, _: ArgInt) !void {
    const buf = try alloc.alloc(u8, std.math.maxInt(usize) / 2);
    alloc.free(buf);
}

fn noFree(alloc: Allocator, _: ArgInt) !void {
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
}

fn doubleFree(alloc: Allocator, _: ArgInt) !void {
    const ptr = try alloc.create(u8);
    alloc.destroy(ptr);
    alloc.destroy(ptr);
}

fn failingTest(alloc: Allocator, _: ArgInt) !void {
    _ = alloc;
    return error.Fail;
}

// Cannot do higher alignment https://github.com/ziglang/zig/issues/22975
fn pageAlign(alloc: Allocator, _: ArgInt) !void {
    const alignment: Alignment = comptime .fromByteUnits(std.heap.page_size_min);

    var validationAllocator = std.mem.validationWrap(alloc);
    const allocator = validationAllocator.allocator();

    var slice = try allocator.alignedAlloc(u8, alignment.toByteUnits(), 500);
    try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));

    if (allocator.resize(slice, 100)) {
        slice = slice[0..100];
    }

    slice = try allocator.realloc(slice, 5000);
    try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));

    if (allocator.resize(slice, 10)) {
        slice = slice[0..10];
    }

    slice = try allocator.realloc(slice, 20000);
    try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));

    allocator.free(slice);
}

fn evictingArray(alloc: Allocator, arg: ArgInt) !void {
    const run = @import("evictingArray.zig").run;

    // Maximally allocate 1Gi
    try run(alloc, .{
        .min_size = 8,
        .max_size = 1 << 15, // 32ki
        .chunks = 1 << 15, // 32Ki
        .num_rounds = 100,
        .thread_count = arg,
    });
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
