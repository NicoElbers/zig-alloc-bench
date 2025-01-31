const test_functions: []const TestInformation = &.{
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
        .name = "No free",
        .charactaristics = .{
            .failing = true,
        },
        .test_fn = &noFree,
    },
    .{
        .name = "Double free",
        .charactaristics = .{
            .failing = true,
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
        },
        .test_fn = &failingTest,
    },
};

const constructor_functions: []const ContructorInformation = &.{
    .{
        .name = "Default GPA",
        .constr_fn = &simpleGpa,
    },
    .{
        .name = "Other GPA",
        .constr_fn = &otherGpa,
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

fn simpleGpa(opts: runner.TestOpts) !profiling.ProfilingAllocator.Res {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn otherGpa(opts: runner.TestOpts) !profiling.ProfilingAllocator.Res {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .retain_metadata = true,
    }).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const config: Config = try .parse(arena.allocator());

    try runner.runAll(config, test_functions, constructor_functions);
}

const std = @import("std");
const runner = @import("runner.zig");
const profiling = @import("profiling.zig");

const Allocator = std.mem.Allocator;
const Config = runner.Config;
const TestFn = runner.TestFn;
const TestInformation = runner.TestInformation;
const ContructorInformation = runner.ContructorInformation;
