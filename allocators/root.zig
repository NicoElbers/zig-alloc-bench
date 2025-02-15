pub const default: []const ContructorInformation = &.{
    .{
        .name = "Debug allocator",
        .characteristics = .default,
        .constr_fn = &debugAlloc,
    },
    .{
        .name = "SMP allocator",
        .characteristics = .default,
        .constr_fn = &smpAlloc,
    },
};

fn debugAlloc(opts: runner.TestOpts) !?Profiling {
    const DebugAllocator = @import("std").heap.DebugAllocator;

    var dbg = DebugAllocator(.{
        .stack_trace_frames = if (@import("std").debug.sys_can_stack_trace) 6 else 0,
        .safety = true,
        .thread_safe = true,
        .retain_metadata = true,
        .resize_stack_traces = true,
    }).init;

    const ret = runner.run(dbg.allocator(), opts);

    if (dbg.deinit() != .ok) return error.Leaked;

    return ret;
}

fn smpAlloc(opts: runner.TestOpts) !?Profiling {
    const smp = @import("std").heap.smp_allocator;

    return runner.run(smp, opts);
}

const runner = @import("runner");
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;
