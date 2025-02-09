pub const TestFn = *const fn (Allocator) anyerror!void;
pub const ConstrFn = *const fn (TestOpts) anyerror!profiling.ProfilingAllocator.Res;

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

    pub const default: TestCharacteristics = .{};
};

pub const TestInformation = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    charactaristics: TestCharacteristics = .default,
    timeout_ns: ?u64 = null,
    test_fn: TestFn,
};

pub const AllocatorCharacteristics = struct {
    thread_safe: bool = false,

    pub const default = .{};
};
pub const ContructorInformation = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    characteristics: AllocatorCharacteristics = .default,
    constr_fn: ConstrFn,
};

pub const TestOpts = struct {
    type: RunOpts.Type,
    test_fn: TestFn,
    timeout_ns: ?u64 = null,
    tty: std.io.tty.Config,
};

pub const Performance = switch (native_os) {
    .linux => struct {
        fds: [events.len]posix.fd_t = @splat(-1),

        pub const Res = extern struct {
            cache_misses: usize,
            cache_references: usize,

            pub fn getCacheMissPercent(self: Res) ?f128 {
                const cm: f128 = @floatFromInt(self.cache_misses);
                const cr: f128 = @floatFromInt(self.cache_references);
                return (cm / cr) * 100;
            }
        };

        const Measurement = struct {
            count: linux.PERF.COUNT.HW = .CPU_CYCLES,
            name: []const u8 = &.{},
        };

        const events: []const Measurement = &.{
            .{ .name = "cache_misses", .count = .CACHE_MISSES },
            .{ .name = "cache_references", .count = .CACHE_REFERENCES },
        };

        comptime {
            assert(std.meta.fields(Res).len == events.len);
        }

        pub fn init() !@This() {
            var self: Performance = .{};

            for (events, 0..) |event, i| {
                var attr: linux.perf_event_attr = .{
                    .type = linux.PERF.TYPE.HARDWARE,
                    .config = @intFromEnum(event.count),
                    .flags = .{
                        .disabled = true,
                        .exclude_kernel = true,
                        .exclude_hv = true,
                        .inherit = true,
                        .enable_on_exec = true,
                    },
                };

                self.fds[i] = try posix.perf_event_open(
                    &attr,
                    0,
                    -1,
                    self.fds[0],
                    0,
                );
            }

            return self;
        }

        fn ioctl(self: *const @This(), req: u32, arg: usize) usize {
            return linux.ioctl(self.fds[0], req, arg);
        }

        pub fn reset(self: @This()) void {
            _ = self.ioctl(linux.PERF.EVENT_IOC.RESET, linux.PERF.IOC_FLAG_GROUP);
            _ = self.ioctl(linux.PERF.EVENT_IOC.ENABLE, linux.PERF.IOC_FLAG_GROUP);
        }

        pub fn read(self: @This()) !Res {
            _ = self.ioctl(linux.PERF.EVENT_IOC.DISABLE, 0);

            var res: Res = undefined;

            inline for (self.fds, events) |fd, event| {
                var val: usize = undefined;
                const n = try posix.read(fd, std.mem.asBytes(&val));
                assert(n == @sizeOf(usize));

                @field(res, event.name) = val;
            }

            return res;
        }

        pub fn deinit(self: *@This()) void {
            for (&self.fds) |*fd| {
                std.posix.close(fd.*);
                fd.* = -1;
            }

            self.* = undefined;
        }
    },
    else => struct {
        pub const Res = extern struct {
            pub fn getCacheMissPercent(_: Res) ?f128 {
                return null;
            }
        };

        pub fn init() !@This() {}
        pub fn reset(_: @This()) void {}
        pub fn read(_: @This()) Res {}
        pub fn deinit(_: *@This()) void {}
    },
};

pub fn run(alloc: Allocator, opts: TestOpts) !ProfilingAllocator.Res {
    return switch (opts.type) {
        .benchmarking => blk: {
            try opts.test_fn(alloc);

            break :blk undefined;
        },
        .testing => @panic("TODO: implement testing"),
        .profiling => blk: {
            var profiler = ProfilingAllocator.init(alloc, std.heap.page_allocator);
            errdefer _ = profiler.dumpErrors(std.io.getStdErr());

            try opts.test_fn(profiler.allocator());

            if (profiler.dumpErrors(std.io.getStdErr())) {
                return error.ProfileError;
            }

            break :blk try profiler.getStats();
        },
    };
}

/// Known exit statuses within the project
pub const StatusCode = enum(u8) {
    success = 0,
    genericError = 1,
    outOfMemory = 2,

    pub const Error = error{
        OutOfMemory,
        GenericError,
    };

    pub fn fromStatus(status: StatusCode) Error!void {
        return switch (status) {
            .success => {},
            .genericError => Error.GenericError,
            .outOfMemory => Error.OutOfMemory,
        };
    }

    pub fn toStatus(err: anyerror) StatusCode {
        return switch (err) {
            error.OutOfMemory => .outOfMemory,
            else => .genericError,
        };
    }

    pub fn codeToStatus(code: u8) StatusCode {
        inline for (std.meta.tags(StatusCode)) |status| {
            if (status.toCode() == code) return status;
        }
        return .genericError;
    }

    pub fn errToCode(err: anyerror) u8 {
        return StatusCode.toStatus(err).toCode();
    }

    pub fn toCode(status: StatusCode) u8 {
        return @intFromEnum(status);
    }

    pub fn exitFatal(err: anyerror, file: ?File) noreturn {
        if (file) |f| {
            f.writer().print("Error: {s}\n", .{@errorName(err)}) catch {};
        }
        std.process.exit(StatusCode.errToCode(err));
    }

    pub fn exitSucess() noreturn {
        std.process.exit(StatusCode.success.toCode());
    }
};

pub const ChildStatistics = extern struct {
    perf: Performance.Res,
    profile: profiling.ProfilingAllocator.Res,
    wall_time_ns: u64,
};
pub const StatsRet = struct {
    term: process.Term,
    stdout: File,
    stderr: File,
    err_pipe: File,
    rusage: posix.rusage,
    stats: ?ChildStatistics,
};

pub fn runOnce(constr_fn: ConstrFn, opts: TestOpts) !StatsRet {
    switch (try process.fork()) {
        .child => |ret| {
            const err_pipe = ret.err_pipe;
            const ipc_write = ret.ipc_write;
            // const ipc_read = fork.ipc_read;

            var perf = Performance.init() catch |err|
                StatusCode.exitFatal(err, err_pipe);

            perf.reset();
            var timer = std.time.Timer.start() catch unreachable;
            const profile_stats = constr_fn(opts) catch |err| {
                if (@errorReturnTrace()) |st| {
                    process.dumpStackTrace(st.*, err_pipe.writer(), opts.tty);
                }
                StatusCode.exitFatal(err, err_pipe);
            };
            const wall_time = timer.read();
            const perf_ret = try perf.read();
            perf.deinit();

            // Dump information on the IPC pipe
            const child_stats: ChildStatistics = .{
                .perf = perf_ret,
                .profile = profile_stats,
                .wall_time_ns = wall_time,
            };

            ipc_write.writer().writeStructEndian(child_stats, .big) catch |err|
                StatusCode.exitFatal(err, err_pipe);

            StatusCode.exitSucess();
        },
        .parent => |ret| {
            defer ret.stdin.close();
            defer ret.ipc_write.close();
            defer ret.ipc_read.close();
            errdefer posix.kill(ret.pid, 9) catch {};

            // std.log.info("child pid: {d}", .{ret.pid});

            var rusage: posix.rusage = undefined;
            const term = try process.waitOnFork(
                ret.pid,
                &rusage,
                opts.timeout_ns,
            );

            const stats: ?ChildStatistics = ret.ipc_read
                .reader()
                .readStructEndian(ChildStatistics, .big) catch null;

            return .{
                .term = term,
                .stdout = ret.stdout,
                .stderr = ret.stderr,
                .err_pipe = ret.err_pipe,
                .rusage = rusage,
                .stats = stats,
            };
        },
    }
    unreachable;
}

pub const RunOpts = struct {
    type: Type,
    filter: []const u8 = "",
    min_runtime_ns: u64 = std.time.ns_per_s * 5,
    tty: std.io.tty.Config = .escape_codes,
    prefix: [:0]const u8 = "runs",
    dry_run: bool = false,

    pub const Type = enum(u8) {
        testing,
        profiling,
        benchmarking,
    };
};

pub const Unit = enum {
    time,
    count,
    memory,
    percent,

    pub fn convert(unit: @This(), value: f128) struct { f128, []const u8 } {
        return switch (unit) {
            .percent => .{ value, "%" },
            inline .memory, .count => |t| blk: {
                const addition = if (t == .memory) "B" else "";

                var limit: f128 = 1;
                inline for (.{ "", "K", "M", "G", "T", "P" }) |name| {
                    defer limit *= 1024;
                    assert(std.math.isNormal(limit));

                    if (value < limit * 1024) {
                        break :blk .{ value / limit, name ++ addition };
                    }
                }
                break :blk .{ value / limit, "P" ++ addition };
            },
            .time => blk: {
                var limit: f128 = 1;
                inline for (
                    .{ 1000, 1000, 1000, 60, 60, 24, 7 },
                    .{ "ns", "us", "ms", "s", "min", "hours", "days" },
                ) |threshold, name| {
                    defer limit *= threshold;

                    if (value < limit * threshold) {
                        break :blk .{ value / limit, name };
                    }
                }
                break :blk .{ value / limit, "days" };
            },
        };
    }
};

fn Tally(comptime T: type, comptime unit: Unit) type {
    switch (@typeInfo(T)) {
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        => {},
        else => @compileError("Not supported"),
    }

    return struct {
        count: u32,
        total_value: f128,

        pub const init: @This() = .{
            .count = 0,
            .total_value = 0,
        };

        pub fn add(self: *@This(), value: T) void {
            self.count += 1;

            self.total_value += switch (@typeInfo(T)) {
                .int, .comptime_int => @floatFromInt(value),
                else => @floatCast(value),
            };
        }

        pub fn get(self: @This()) struct { f128, []const u8 } {
            if (self.count == 0) return unit.convert(0);
            const val = self.total_value / @as(f128, @floatFromInt(self.count));

            return unit.convert(val);
        }
    };
}

pub const RunStats = struct {
    runs: u32 = 0,
    total_time: Tally(u64, .time) = .init,
    total_cache_miss_percent: Tally(f128, .percent) = .init,
    allocations: Tally(u64, .count) = .init,
    total_max_rss: Tally(u64, .memory) = .init,
};

pub fn runAll(
    alloc: Allocator,
    test_fns: []const TestInformation,
    constructors: []const ContructorInformation,
    opts: RunOpts,
) !void {
    var logger: RunLogger = try .init(alloc, opts.prefix, opts.type, opts.dry_run);
    errdefer logger.deinit(alloc);

    std.log.info("Running up to {d} permutations", .{test_fns.len * constructors.len});
    const stderr = std.io.getStdErr();
    const stdout = std.io.getStdOut();

    var fail_count: u32 = 0;

    tests: for (test_fns) |test_info| {
        if (opts.type == .benchmarking and test_info.charactaristics.failing) continue;

        if (opts.filter.len > 0) blk: {
            if (std.mem.eql(u8, opts.filter, test_info.name)) break :blk;
            continue :tests;
        }

        try stdout.writer().print(
            \\ 
            \\ ==== {s} ====
            \\
        , .{
            test_info.name,
        });

        for (constructors) |constr_info| {
            const test_opts: TestOpts = .{
                .type = opts.type,
                .test_fn = test_info.test_fn,
                .timeout_ns = test_info.timeout_ns,
                .tty = opts.tty,
            };

            var running_stats: RunStats = .{};

            const runtime: u64 = if (opts.type == .testing or test_info.charactaristics.failing)
                0
            else
                opts.min_runtime_ns;

            var ran_once = false;
            var timer = std.time.Timer.start() catch unreachable;
            const failed = loop: while (timer.read() < runtime or !ran_once) {
                defer ran_once = true;

                const ret: StatsRet = try runOnce(constr_info.constr_fn, test_opts);

                defer ret.err_pipe.close();
                defer ret.stderr.close();
                defer ret.stdout.close();

                switch (ret.term) {
                    inline else => |v, t| {
                        if (!test_info.charactaristics.failing) {
                            try dumpFile("stdout", ret.stdout, stderr);
                            try dumpFile("stderr", ret.stderr, stderr);
                            try dumpFile("Error", ret.err_pipe, stderr);
                            try stderr.writer().print("Terminated because {s}: {any}\n", .{ @tagName(t), v });

                            break :loop true;
                        }
                    },
                    .Exited => |code| {
                        const status = process.StatusCode.codeToStatus(code);
                        switch (status) {
                            .success => {
                                if (test_info.charactaristics.failing) {
                                    try dumpFile("stdout", ret.stdout, stderr);
                                    try dumpFile("stderr", ret.stderr, stderr);
                                    try dumpFile("Error", ret.err_pipe, stderr);
                                    try stderr.writer().print("Expected failure but was successful", .{});
                                    break :loop true;
                                }
                            },
                            inline else => |t| {
                                if (!test_info.charactaristics.failing) {
                                    try dumpFile("stdout", ret.stdout, stderr);
                                    try dumpFile("stderr", ret.stderr, stderr);
                                    try dumpFile("Error", ret.err_pipe, stderr);
                                    try stderr.writer().print("Exited with code {s}: \n", .{@tagName(t)});
                                    break :loop true;
                                }
                            },
                        }
                    },
                }

                running_stats.runs += 1;
                if (ret.stats) |stats| {
                    running_stats.total_time.add(stats.wall_time_ns);
                    running_stats.total_cache_miss_percent.add(stats.perf.getCacheMissPercent() orelse 100);
                    running_stats.allocations.add(stats.profile.allocations);
                }
                running_stats.total_max_rss.add(@intCast(ret.rusage.maxrss * 1024));
            } else false;

            try logger.update(alloc, running_stats);

            if (failed) {
                std.log.err("Permutation failed", .{});
                if (opts.type != .testing) return;
                fail_count += 1;
            } else {
                const max_rss = running_stats.total_max_rss.get();
                try stdout.writer().print(
                    \\ 
                    \\ ---- {s} ----
                    \\
                    \\ Over {d} run{s}: 
                    \\  - max rss       : {d: >6.2} {s}
                    \\
                , .{
                    constr_info.name,
                    running_stats.runs,
                    if (running_stats.runs > 1) "s" else "",
                    max_rss.@"0",
                    max_rss.@"1",
                });

                if (opts.type == .profiling) {
                    const allocations = running_stats.allocations.get();
                    try stdout.writer().print(
                        \\  - allocations   : {d: >6.0} {s}
                        \\
                    , allocations);
                }

                if (opts.type != .profiling) {
                    const cache_misses = running_stats.total_cache_miss_percent.get();
                    try stdout.writer().print(
                        \\  - cache misses  : {d: >6.2} {s}
                        \\
                    , .{
                        cache_misses.@"0",
                        cache_misses.@"1",
                    });
                }

                if (opts.type == .benchmarking) {
                    const time = running_stats.total_time.get();
                    try stdout.writer().print(
                        \\  - time          : {d: >6.2} {s}
                        \\
                    , .{
                        time.@"0",
                        time.@"1",
                    });
                }
            }
        }
    }

    if (fail_count > 0) {
        try stderr.writer().print(
            "{d} permutations failed\n",
            .{fail_count},
        );
    }

    try logger.finish(alloc);
}

fn dumpFile(file_name: []const u8, read: File, write: File) !void {
    var buf: [1024]u8 = undefined;

    var written_anything = false;
    while (true) {
        const amt = read.read(&buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (amt == 0) break;
        defer written_anything = true;

        if (!written_anything) {
            try write.writer().print("----- {s} ----\n", .{file_name});
        }

        try write.writeAll(buf[0..amt]);
    }

    if (written_anything) {
        try write.writer().print("----- {s} ----\n\n", .{file_name});
    }
}

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const profiling = @import("profiling.zig");
const process = @import("process.zig");
const builtin = @import("builtin");

const assert = std.debug.assert;

const native_os = builtin.os.tag;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ProfilingAllocator = profiling.ProfilingAllocator;
const RunLogger = @import("RunLogger.zig");
