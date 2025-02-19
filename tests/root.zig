pub const default = [_]TestInformation{
    .{
        .name = "First allocation",
        .test_fn = &firstAlloc,
        .arg = .{ .exponential = .{ .n = 20 } },
        .rerun = .{
            .run_at_least = 100,
            .run_for_ns = 0,
        },
    },
    .{
        .name = "Many allocations and frees",
        .test_fn = &manyAllocFree,
        .timeout_ns = std.time.ns_per_s,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
    },
    .{
        .name = "Many allocations, resizes and frees",
        .test_fn = &manyAllocResizeFree,
        .timeout_ns = std.time.ns_per_s,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
    },
    .{
        .name = "Many allocations, remaps and frees",
        .test_fn = &manyAllocRemapsFree,
        .timeout_ns = std.time.ns_per_s * 2,
        .arg = .{ .exponential = .{ .start = 1024, .n = 10 } },
    },
    .{
        .name = "Appending to many arraylists",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &appendingToMultipleArrayLists,
        .arg = .{ .exponential = .{ .start = 1, .n = 10 } },
    },
    .{
        .name = "Random access append",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &appendAccessArray,
        .arg = .{ .exponential = .{ .start = 1024, .n = 5 } },
    },
    .{
        .name = "No free",
        .charactaristics = .{
            .failure = .any_failure,
            .testing = true,
        },
        .rerun = .once,
        .test_fn = &noFree,
    },
    .{
        .name = "Double free",
        .charactaristics = .{
            .failure = .any_failure,
            .testing = true,
        },
        .rerun = .once,
        .test_fn = &doubleFree,
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
        .rerun = .once,
        .test_fn = &failingTest,
    },
    .{
        .name = "Basic alignment",
        .charactaristics = .{
            .testing = true,
        },
        .rerun = .once,
        .test_fn = &alignmentFn,
    },
    .{
        .name = "Aligned allocs",
        .charactaristics = .default,
        .test_fn = &alignedAllocs,
    },
};

fn firstAlloc(alloc: Allocator, arg: ArgInt) !void {
    const a = try alloc.alloc(u8, arg);
    defer alloc.free(a);
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

const repetitions = 100;

const Types = [_]type{
    u8,            u32,                     u16,                     u128,
    u256,          u512,                    u1024,                   u2048,
    struct { u8 }, extern struct { a: u8 }, packed struct { a: u8 }, struct {},
    usize,         *u8,
};

fn alignmentFn(alloc: Allocator, _: ArgInt) !void {
    inline for (Types) |T| {
        var ptrs: [repetitions]*T = undefined;

        for (0..repetitions) |i| {
            const elem = try alloc.create(T);
            ptrs[i] = elem;

            try std.testing.expect(@intFromPtr(elem) % @alignOf(T) == 0);
        }

        for (ptrs) |ptr| alloc.destroy(ptr);
    }

    inline for (Types) |T| {
        var ptrs: [repetitions][]T = undefined;

        for (0..repetitions) |i| {
            const arr = try alloc.alloc(T, 123);
            ptrs[i] = arr;

            try std.testing.expect(@intFromPtr(arr.ptr) % @alignOf(T) == 0);
        }

        for (ptrs) |ptr| alloc.free(ptr);
    }
}

const Alignments = [_]Alignment{
    .@"1",
    .@"2",
    .@"4",
    .@"8",
    .@"16",
    .@"32",
    .@"64",

    // Biggest power of 2
    @enumFromInt(std.math.log2_int(u29, 1 << 28)),

    // Biggest value
    @enumFromInt(std.math.log2_int(u29, 1 << 29 - 1)),
};

fn alignedAllocs(alloc: Allocator, _: ArgInt) !void {
    inline for (Types) |T| {
        inline for (Alignments) |alignm| {
            var ptrs: [repetitions][]align(alignm.toByteUnits()) T = undefined;

            var prng = std.Random.DefaultPrng.init(0xdeadbeef);
            const rand = prng.random();

            for (0..repetitions) |i| {
                const arr = try allocAlignedRange(T, rand, alloc, alignm, 1, 1_000);
                ptrs[i] = arr;

                touchAllocation(rand, arr);

                try std.testing.expect(@intFromPtr(arr.ptr) % alignm.toByteUnits() == 0);
            }

            for (ptrs) |ptr| alloc.free(ptr);
        }
    }
}

// ---- Common functions ----

/// Minially touch an allocation, to ensure it actually exists, but to influence
/// time as little as possible
inline fn touchAllocation(rand: Random, allocation: anytype) void {
    const info = @typeInfo(@TypeOf(allocation)).pointer;

    if (@typeInfo(info.child) != .int) {
        switch (info.size) {
            .one => allocation.* = undefined,
            .slice => {
                allocation[0] = undefined;
                allocation[allocation.len - 1] = undefined;
            },
            else => comptime unreachable,
        }
        return;
    }

    switch (info.size) {
        .one => allocation.* = rand.int(info.child),
        .slice => {
            allocation[0] = rand.int(info.child);
            allocation[allocation.len - 1] = rand.int(info.child);
        },
        else => comptime unreachable,
    }
}

inline fn allocRange(comptime T: type, rand: Random, alloc: Allocator, min: usize, max: usize) ![]T {
    return alloc.alloc(T, rand.intRangeAtMost(usize, min, max));
}

inline fn allocAlignedRange(comptime T: type, rand: Random, alloc: Allocator, comptime alignment: Alignment, min: usize, max: usize) ![]align(alignment.toByteUnits()) T {
    return alloc.alignedAlloc(T, alignment.toByteUnits(), rand.intRangeAtMost(usize, min, max));
}

const std = @import("std");
const runner = @import("runner");
const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Random = std.Random;
const Alignment = std.mem.Alignment;
