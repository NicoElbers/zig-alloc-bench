pub const TestFn = *const fn (Allocator) anyerror!void;

pub const TestCharacteristics = struct {
    leaks: bool = false,
    multithreaded: bool = false,
    long_running: bool = false,

    /// Avoid flaky tests if possible
    flaky: bool = false,

    /// Meta test to test the existing infrastructure
    meta: bool = false,

    /// A failing test is supposed to emit some error
    failing: bool = false,

    testing: bool = false,

    pub const default: TestCharacteristics = .{};
};

pub const TestInformation = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    charactaristics: TestCharacteristics = .default,
    timeout_ns: ?u64 = null,
    test_fn: TestFn,
};

pub const ConstrFn = *const fn (TestOpts) anyerror!void;

pub const AllocatorCharacteristics = struct {
    thread_safe: bool = true,

    pub const default = .{};
};
pub const ContructorInformation = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    characteristics: AllocatorCharacteristics,
    constr_fn: ConstrFn,
};

pub const TestOpts = struct {
    type: Opts.Type,
    test_fn: TestFn,
    timeout_ns: ?u64 = null,
    tty: std.io.tty.Config,
    profiling: *Profiling,
};

pub const Profiling = statistics.Profiling;

pub fn run(alloc: Allocator, opts: TestOpts) !void {
    return switch (opts.type) {
        .testing, .benchmarking => try opts.test_fn(alloc),
        .profiling => {
            var profiler = ProfilingAllocator.init(alloc, opts.profiling);

            try opts.test_fn(profiler.allocator());
        },
    };
}

pub const StatsRet = struct {
    term: process.Term,
    stdout: File,
    stderr: File,
    err_pipe: File,
    rusage: posix.rusage,
    performance: Performance.Ret,
    profiling: ?Profiling,

    pub fn deinit(self: @This()) void {
        self.err_pipe.close();
        self.stderr.close();
        self.stdout.close();
    }
};

pub const ChildRet = struct {
    performance: Performance.Ret,
    profiling: ?Profiling,
};

pub fn runOnce(alloc: Allocator, constr_fn: ConstrFn, opts: TestOpts) !StatsRet {
    switch (try process.fork()) {
        .child => |ret| {
            const err_pipe = ret.err_pipe;
            const ipc_write = ret.ipc_write;
            // const ipc_read = fork.ipc_read;

            var stats = Performance.init() catch |err|
                StatusCode.exitFatal(err, err_pipe);

            constr_fn(opts) catch |err| {
                if (@errorReturnTrace()) |st| {
                    process.dumpStackTrace(st.*, err_pipe.writer(), opts.tty);
                }
                StatusCode.exitFatal(err, err_pipe);
            };

            // FIXME: This is ugly
            //
            // For future reference, this is taking in a profiling instance
            // to write it all at once in a second
            const perf = stats.read() catch |err|
                StatusCode.exitFatal(err, err_pipe);
            stats.deinit();

            const child_ret: ChildRet = .{
                .performance = perf,
                .profiling = if (opts.type == .profiling)
                    opts.profiling.*
                else
                    null,
            };

            // Dump information on the IPC pipe
            @setEvalBranchQuota(2000);
            std.zon.stringify.serialize(child_ret, .{ .whitespace = false }, ipc_write.writer()) catch |err|
                StatusCode.exitFatal(err, err_pipe);

            StatusCode.exitSucess();
            unreachable; // Defensive, child may never escape this scope
        },
        .parent => |ret| {
            defer ret.stdin.close();
            defer ret.ipc_read.close();

            var rusage: posix.rusage = undefined;
            const term = try process.waitOnFork(
                ret.pid,
                &rusage,
                opts.timeout_ns,
            );

            const stats: ChildRet = if (opts.type == .testing)
                undefined
            else blk: {
                var buf: [4096]u8 = undefined;
                const amt = try ret.ipc_read.read(&buf);

                // -1 because we need to make it sentinel terminated
                if (amt >= buf.len - 1) return error.BufferTooSmall;

                // HACK: ew
                buf[amt] = 0;
                const source: [:0]const u8 = @ptrCast(buf[0..amt]);

                comptime assert(!requiresAllocator(ChildRet));
                break :blk try std.zon.parse.fromSlice(
                    ChildRet,
                    alloc,
                    source,
                    null,
                    .{},
                );
            };

            return .{
                .term = term,
                .stdout = ret.stdout,
                .stderr = ret.stderr,
                .err_pipe = ret.err_pipe,
                .rusage = rusage,
                .performance = stats.performance,
                .profiling = stats.profiling,
            };
        },
    }
    unreachable;
}

// remove with https://github.com/ziglang/zig/pull/22835
fn requiresAllocator(T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| return array.len > 0 and requiresAllocator(array.child),
        .@"struct" => |@"struct"| inline for (@"struct".fields) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .@"union" => |@"union"| inline for (@"union".fields) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .optional => |optional| requiresAllocator(optional.child),
        .vector => |vector| return vector.len > 0 and requiresAllocator(vector.child),
        else => false,
    };
}

pub const Opts = struct {
    type: Type,
    filter: ?[]const u8 = null,
    min_runtime_ns: u64 = std.time.ns_per_s * 5,
    tty: std.io.tty.Config = .escape_codes,
    prefix: [:0]const u8 = "runs",
    dry_run: bool = false,
    quiet: bool = false,

    pub const Type = enum(u8) {
        testing,
        profiling,
        benchmarking,
    };
};

pub fn runAll(
    alloc: Allocator,
    tests: []const TestInformation,
    constrs: []const ContructorInformation,
    opts: Opts,
) !void {
    var logger: RunLogger = try .init(alloc, .{
        .type = opts.type,
        .cli = !opts.quiet,
        .disk = !opts.dry_run,
        .prefix = opts.prefix,
    });
    defer logger.finish(alloc) catch |err| @panic(@errorName(err));

    // TODO: Ugly
    const filter: Filter = .init(if (opts.filter) |f| &.{f} else null, null, .{
        .type = opts.type,
        .meta = true,
    });

    std.log.info("Running {d} permutations", .{filter.countSurviving(tests, constrs)});

    tests: for (tests) |test_info| {
        if (filter.filterTest(test_info)) continue :tests;

        try logger.startTest(test_info);

        constrs: for (constrs) |constr_info| {
            if (filter.filterCombination(test_info, constr_info)) continue :constrs;

            try logger.startConstr(constr_info);

            var current_run: Run = .init;

            const test_opts: TestOpts = .{
                .type = opts.type,
                .test_fn = test_info.test_fn,
                .timeout_ns = test_info.timeout_ns,
                .tty = opts.tty,
                .profiling = &current_run.profiling,
            };

            const runtime: u64 = if (opts.type == .testing or test_info.charactaristics.failing)
                0
            else
                opts.min_runtime_ns;

            var ran_once = false;
            var any_failed = false;
            var timer = std.time.Timer.start() catch unreachable;
            while (timer.read() < runtime or !ran_once) {
                defer ran_once = true;

                const ret: StatsRet = try runOnce(alloc, constr_info.constr_fn, test_opts);
                defer ret.deinit();

                switch (ret.term) {
                    inline else => |v, t| {
                        if (!test_info.charactaristics.failing) {
                            try logger.runFail(ret, @tagName(t), if (@TypeOf(v) == void) 0 else v);
                            if (opts.type != .testing) return;
                            any_failed = true;
                            break;
                        }
                    },
                    .Exited => |code| {
                        const status = StatusCode.codeToStatus(code);
                        switch (status) {
                            .success => {
                                if (test_info.charactaristics.failing) {
                                    try logger.runFail(ret, "Succeeded failing test", code);
                                    if (opts.type != .testing) return;
                                    any_failed = true;
                                    break;
                                }
                            },
                            inline else => |t| {
                                if (!test_info.charactaristics.failing) {
                                    try logger.runFail(ret, @tagName(t), code);
                                    if (opts.type != .testing) return;
                                    any_failed = true;
                                    break;
                                }
                            },
                        }
                    },
                }

                current_run.runs += 1;
                current_run.time.add(@floatFromInt(ret.performance.wall_time));
                current_run.cache_miss_percent.add(ret.performance.perf.getCacheMissPercent());
                current_run.max_rss.add(@floatFromInt(ret.rusage.maxrss * 1024));
                if (opts.type == .profiling) {
                    current_run.profiling = ret.profiling.?;
                }
            }

            if (!any_failed) {
                try logger.runSucess(alloc, &current_run);
            }
        }
    }
}

const FilterOpts = struct {
    type: Opts.Type,
    meta: bool,
};

const Filter = struct {
    test_whitelist: ?[]const []const u8,
    constr_whitelist: ?[]const []const u8,
    opts: FilterOpts,

    pub fn init(
        test_whitelist: ?[]const []const u8,
        constr_whitelist: ?[]const []const u8,
        opts: FilterOpts,
    ) Filter {
        return .{
            .test_whitelist = test_whitelist,
            .constr_whitelist = constr_whitelist,
            .opts = opts,
        };
    }

    pub fn countSurviving(
        self: Filter,
        tests: []const TestInformation,
        constrs: []const ContructorInformation,
    ) u32 {
        var count: u32 = 0;
        for (tests) |test_info| {
            if (self.filterTest(test_info)) continue;
            for (constrs) |constr_info| {
                if (!self.filterCombination(test_info, constr_info)) count += 1;
            }
        }

        return count;
    }

    pub fn filterTest(self: Filter, test_info: TestInformation) bool {
        const test_chars = test_info.charactaristics;

        // Skip all failing tests except when in testing mode
        if (test_chars.testing and self.opts.type != .testing) return true;

        // Whitelist
        if (self.test_whitelist) |whitelist| {
            for (whitelist) |item|
                if (!std.mem.eql(u8, item, test_info.name)) return true;
        }

        return false;
    }

    pub fn filterCombination(self: Filter, test_info: TestInformation, constr_info: ContructorInformation) bool {
        const test_chars = test_info.charactaristics;
        const constr_chars = constr_info.characteristics;

        // If the test requires multiple threads, but the allocator is single
        // threaded, skip
        if (test_chars.multithreaded and !constr_chars.thread_safe) return true;

        // If we're not running meta tests, skip them
        if (test_chars.meta and !self.opts.meta) return true;

        // Whitelist
        if (self.constr_whitelist) |whitelist| {
            for (whitelist) |item|
                if (!std.mem.eql(u8, item, constr_info.name)) return true;
        }

        return false;
    }
};

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const profiling = @import("profiling.zig");
const process = @import("process.zig");
const builtin = @import("builtin");
const statistics = @import("statistics.zig");

const assert = std.debug.assert;

const native_os = builtin.os.tag;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ProfilingAllocator = profiling.ProfilingAllocator;
const RunLogger = @import("RunLogger.zig");
const Performance = @import("Performance.zig");
const StatusCode = process.StatusCode;
const Random = std.Random;
const Run = statistics.Run;
