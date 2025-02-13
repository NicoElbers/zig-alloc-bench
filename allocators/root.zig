pub const default: []const ContructorInformation = &.{
    .{
        .name = "Default GPA",
        .constr_fn = &simpleGpa,
    },
    .{
        .name = "Other GPA",
        .constr_fn = &otherGpa,
    },
};

fn simpleGpa(opts: runner.TestOpts) !?Profiling {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn otherGpa(opts: runner.TestOpts) !?Profiling {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .retain_metadata = true,
    }).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

const std = @import("std");
const runner = @import("runner");
const TestFn = runner.TestFn;
const Profiling = runner.Profiling;
const ContructorInformation = runner.ContructorInformation;
