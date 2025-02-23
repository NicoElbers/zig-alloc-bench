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
    .{
        .name = "rpmalloc",
        .characteristics = .default,
        .constr_fn = &rpmallocAllocator,
    },
} };

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

fn rpmallocAllocator(opts: TestOpts) !void {
    const rpmalloc = @import("rpmalloc.zig");
    const alloc = rpmalloc.init();
    defer rpmalloc.deinit();

    return runner.run(alloc, opts);
}
const std = @import("std");
const runner = @import("runner");
const TestOpts = runner.TestOpts;
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;

const Allocator = std.mem.Allocator;
