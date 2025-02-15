pub const default = [_]TestInformation{
    .{
        .name = "Simple allocation",
        .test_fn = &simpleTest,
    },
    .{
        .name = "Many allocations and frees",
        .test_fn = &manyAllocFree,
    },
    .{
        .name = "Many allocations, resizes and frees",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &manyAllocResizeFree,
    },
    .{
        .name = "Appending to arraylist",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &appendingToArrayList,
    },
    .{
        .name = "Appending to many arraylists",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &appendingToMultipleArrayLists,
    },
    .{
        .name = "No free",
        .charactaristics = .{
            .failing = true,
            .testing = true,
        },
        .test_fn = &noFree,
    },
    .{
        .name = "Double free",
        .charactaristics = .{
            .failing = true,
            .testing = true,
        },
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
            .failing = true,
            .testing = true,
        },
        .test_fn = &failingTest,
    },
    .{
        .name = "Basic alignment",
        .charactaristics = .{
            .testing = true,
        },
        .test_fn = &alignment,
    },
    .{
        .name = "Aligned allocs",
        .charactaristics = .default,
        .test_fn = &alignedAllocs,
    },
};

fn simpleTest(alloc: Allocator) !void {
    const a = try alloc.alloc(u8, 1000);
    defer alloc.free(a);
}

fn manyAllocFree(alloc: Allocator) !void {
    for (0..10_000) |_| {
        const arr = try alloc.alloc(u32, 100);
        alloc.free(arr);
    }
}

fn manyAllocResizeFree(alloc: Allocator) !void {
    for (0..10_000) |_| {
        const arr = try alloc.alloc(u32, 100);
        // _ = alloc.resize(arr, 50);
        alloc.free(arr);
    }
}

fn appendingToArrayList(alloc: Allocator) !void {
    var arr = std.ArrayListUnmanaged(u64).empty;
    defer arr.deinit(alloc);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        try arr.append(alloc, rand.int(u64));
    }
}

fn appendingToMultipleArrayLists(alloc: Allocator) !void {
    var arrs: [10]std.ArrayListUnmanaged(u64) = @splat(.empty);
    defer for (&arrs) |*arr| arr.deinit(alloc);

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    for (0..10_000) |_| {
        const idx = rand.intRangeAtMost(u64, 0, arrs.len - 1);
        try arrs[idx].append(alloc, rand.int(u64));
    }
}

fn oomTest(alloc: Allocator) !void {
    const buf = try alloc.alloc(u8, std.math.maxInt(usize) / 2);
    alloc.free(buf);
}

fn noFree(alloc: Allocator) !void {
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
}

fn doubleFree(alloc: Allocator) !void {
    const ptr = try alloc.create(u8);
    alloc.destroy(ptr);
    alloc.destroy(ptr);
}

fn failingTest(alloc: Allocator) !void {
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

fn alignment(alloc: Allocator) !void {
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

const Alignments = [_]std.mem.Alignment{
    .@"1",
    .@"2",
    .@"4",
    .@"8",
    .@"16",
    .@"32",
    .@"64",

    @enumFromInt(std.math.log2_int(u29, 1 << 28)),
    @enumFromInt(std.math.log2_int(u29, 1 << 29 - 1)),
};

fn alignedAllocs(alloc: Allocator) !void {
    inline for (Types) |T| {
        inline for (Alignments) |alignm| {
            var ptrs: [repetitions][]align(alignm.toByteUnits()) T = undefined;

            for (0..repetitions) |i| {
                const arr = try alloc.alignedAlloc(T, @intCast(alignm.toByteUnits()), 123);
                ptrs[i] = arr;

                @memset(arr, undefined);

                try std.testing.expect(@intFromPtr(arr.ptr) % alignm.toByteUnits() == 0);
            }

            for (ptrs) |ptr| alloc.free(ptr);
        }
    }
}

const std = @import("std");
const runner = @import("runner");
const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
