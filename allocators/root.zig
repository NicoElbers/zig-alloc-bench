pub const default = [_]ContructorInformation{
    .{
        .name = "SMP allocator",
        .characteristics = .default,
        .constr_fn = &smpAlloc,
    },
    .{
        .name = "Debug allocator",
        .characteristics = .{
            .safety = true,
        },
        .constr_fn = &debugAlloc,
    },
    .{
        .name = "Page allocator",
        .characteristics = .default,
        .constr_fn = &pageAlloc,
    },
};

fn debugAlloc(opts: TestOpts) !void {
    const DebugAllocator = std.heap.DebugAllocator;

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

fn smpAlloc(opts: TestOpts) !void {
    const smp = std.heap.smp_allocator;

    return runner.run(smp, opts);
}

fn pageAlloc(opts: TestOpts) !void {
    const page: Allocator = .{ .ptr = undefined, .vtable = &std.heap.PageAllocator.vtable };

    return runner.run(page, opts);
}

const std = @import("std");
const runner = @import("runner");
const TestOpts = runner.TestOpts;
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;

const Allocator = std.mem.Allocator;
