pub const default =
    correctness ++
    micro ++
    mimalloc ++
    playback;

pub const correctness = @import("correctness.zig").correctness;
pub const micro = @import("micro.zig").micro;
pub const mimalloc = @import("mimalloc-bench.zig").tests;
pub const playback = @import("playback.zig").tests;

const unused = [_]TestInformation{
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
};

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

const assert = std.debug.assert;
const allocRange = common.allocRange;
const touchAllocation = common.touchAllocation;

const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Random = std.Random;
const Alignment = std.mem.Alignment;
const Thread = std.Thread;
