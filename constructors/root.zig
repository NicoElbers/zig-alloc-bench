pub const default = [_]ContructorInformation{
    .{
        .name = "std SMP allocator",
        .characteristics = .default,
        .constr_fn = &stdSmpAllocator,
    },
    .{
        .name = "std Debug allocator",
        .characteristics = .{
            .safety = true,
        },
        .constr_fn = &stdDebugAllocator,
    },
    .{
        .name = "std Page allocator",
        .characteristics = .default,
        .constr_fn = &stdPageAllocator,
    },
    .{
        .name = "binned allocator",
        .characteristics = .default,
        .constr_fn = &binnedAllocator,
    },
} ++ libc_allocator ++ jemalloc ++ mimalloc ++ rpmalloc;

fn stdSmpAllocator(opts: TestOpts) !void {
    const smp: Allocator = .{
        .ptr = undefined,
        .vtable = &@import("std_SmpAllocator.zig").vtable,
    };

    return runner.run(smp, opts);
}

fn stdDebugAllocator(opts: TestOpts) !void {
    const DebugAllocator = @import("std_debug_allocator.zig").DebugAllocator;

    var dbg = DebugAllocator(.{
        .stack_trace_frames = if (std.debug.sys_can_stack_trace) 6 else 0,
        .safety = true,
        .thread_safe = true,
        .retain_metadata = true,
        .resize_stack_traces = true,
    }).init;

    const ret = runner.run(dbg.allocator(), opts);

    if (dbg.deinit() != .ok) return error.Leaked;

    return ret;
}

fn stdPageAllocator(opts: TestOpts) !void {
    const page: Allocator = .{
        .ptr = undefined,
        .vtable = &@import("std_PageAllocator.zig").vtable,
    };

    return runner.run(page, opts);
}

fn binnedAllocator(opts: TestOpts) !void {
    var binned = @import("silversquirl_binned_allocator.zig").BinnedAllocator(.{}){};
    defer binned.deinit();

    return runner.run(binned.allocator(), opts);
}

pub const rpmalloc = if (config.mimalloc)
    [_]ContructorInformation{.{
        .name = "rpmalloc",
        // Due to rpmalloc me not propery setting up rpmalloc (idk how to),
        // multithreading does not work
        .characteristics = .{ .thread_safe = false },
        .constr_fn = &rpmallocAllocator,
    }}
else
    [_]ContructorInformation{};

fn rpmallocAllocator(opts: TestOpts) !void {
    const alloc = @import("rpmalloc.zig").init();
    defer @import("rpmalloc.zig").deinit();

    return runner.run(alloc, opts);
}

pub const jemalloc = if (config.jemalloc)
    [_]ContructorInformation{.{
        .name = "jemalloc",
        .characteristics = .default,
        .constr_fn = &jemallocAllocator,
    }}
else
    [_]ContructorInformation{};

fn jemallocAllocator(opts: TestOpts) !void {
    const alloc = @import("jemalloc").allocator;

    return runner.run(alloc, opts);
}

pub const mimalloc = if (config.mimalloc)
    [_]ContructorInformation{.{
        .name = "mimalloc",
        .characteristics = .default,
        .constr_fn = &mimallocAllocator,
    }}
else
    [_]ContructorInformation{};

fn mimallocAllocator(opts: TestOpts) !void {
    const alloc: Allocator = @import("mimalloc").allocator;

    return runner.run(alloc, opts);
}

pub const libc_allocator = if (config.use_libc)
    [_]ContructorInformation{.{
        .name = @tagName(abi) ++ " libc",
        .characteristics = .default,
        .constr_fn = &stdSmpAllocator,
    }}
else
    [_]ContructorInformation{};

fn libcAllocator(opts: TestOpts) !void {
    const alloc = std.heap.c_allocator;

    return runner.run(alloc, opts);
}

fn optional(comptime cond: bool, info: ContructorInformation) []const ContructorInformation {
    return if (cond)
        &.{info}
    else
        &.{};
}

const std = @import("std");
const runner = @import("runner");
const builtin = @import("builtin");
const config = @import("config");

const link_libc = builtin.link_libc;
const abi = builtin.abi;

const TestOpts = runner.TestOpts;
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;

const Allocator = std.mem.Allocator;
