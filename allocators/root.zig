pub const default = [_]ContructorInformation{
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
    .{
        .name = "Page allocator",
        .characteristics = .default,
        .constr_fn = &pageAlloc,
    },
};

fn debugAlloc(opts: TestOpts) !void {
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

fn smpAlloc(opts: TestOpts) !void {
    const smp = @import("std").heap.smp_allocator;

    return runner.run(smp, opts);
}

fn pageAlloc(opts: TestOpts) !void {
    const page = @import("std").heap.page_allocator;

    return runner.run(page, opts);
}

const runner = @import("runner");
const TestOpts = runner.TestOpts;
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;
