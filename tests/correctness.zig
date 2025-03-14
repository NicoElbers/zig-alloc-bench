/// Tests that verify the correctness of an allocator
pub const correctness = [_]TestInformation{
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
        .name = "Passing test",
        .description =
        \\ A meta test that does nothing, ensuring that every constructor
        \\ runs correctly
        ,
        .charactaristics = .{
            .meta = true,
            .failure = .no_failure,
            .testing = true,
        },
        .test_fn = &passingTest,
    },
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
    .{
        .name = "OOM failure",
        .charactaristics = .{
            .failure = .any_failure,
            .testing = true,
        },
        .test_fn = &oomTest,
    },

    .{
        .name = "mstress",
        .test_fn = &mstress,
        .charactaristics = .{
            .multithreaded = true,
            .long_running = true,
            .testing = true,
        },
        .timeout_ns = std.time.ns_per_s * 30,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = 0,
        },
    },
};

fn stdTests(alloc: Allocator, _: ArgInt) !void {
    try std.heap.testAllocator(alloc);
    try std.heap.testAllocatorAligned(alloc);
    try std.heap.testAllocatorLargeAlignment(alloc);
    try std.heap.testAllocatorAlignedShrink(alloc);
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

fn failingTest(_: Allocator, _: ArgInt) !void {
    return error.Fail;
}

fn passingTest(_: Allocator, _: ArgInt) !void {}

fn mstress(alloc: Allocator, _: ArgInt) !void {
    const run = @import("mstress/mstress.zig").run;

    const cpu = getCpuCount() catch 1;

    try run(alloc, .{
        .thread_count = cpu,
        .scale = 50,
        .iter = 50,
        .transfer_count = 1000,
    });
}

const std = @import("std");
const runner = @import("runner");
const common = @import("common.zig");

const assert = std.debug.assert;
const allocRange = common.allocRange;
const touchAllocation = common.touchAllocation;
const getCpuCount = Thread.getCpuCount;

const Allocator = std.mem.Allocator;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Alignment = std.mem.Alignment;
const Thread = std.Thread;
