pub const TestFn = *const fn (Allocator) anyerror!void;
pub const ConstrFn = *const fn (TestOpts) anyerror!?Statistics.Profiling;

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

pub fn run(alloc: Allocator, opts: TestOpts) !?Statistics.Profiling {
    return switch (opts.type) {
        .benchmarking => blk: {
            try opts.test_fn(alloc);

            break :blk null;
        },
        .testing => @panic("TODO: implement testing"),
        .profiling => blk: {
            var profiler = ProfilingAllocator.init(alloc, std.heap.page_allocator);
            errdefer _ = profiler.dumpErrors(std.io.getStdErr());

            try opts.test_fn(profiler.allocator());

            // FIXME: ew error
            if (profiler.dumpErrors(std.io.getStdErr())) {
                return error.ProfileError;
            }

            // FIXME: touch profiler
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

pub const StatsRet = struct {
    term: process.Term,
    stdout: File,
    stderr: File,
    err_pipe: File,
    rusage: posix.rusage,
    stats: ?Statistics.Ret,
};

pub fn runOnce(alloc: Allocator, constr_fn: ConstrFn, opts: TestOpts) !StatsRet {
    switch (try process.fork()) {
        .child => |ret| {
            const err_pipe = ret.err_pipe;
            const ipc_write = ret.ipc_write;
            // const ipc_read = fork.ipc_read;

            var stats = Statistics.init() catch |err|
                StatusCode.exitFatal(err, err_pipe);

            const profile_stats = constr_fn(opts) catch |err| {
                if (@errorReturnTrace()) |st| {
                    process.dumpStackTrace(st.*, err_pipe.writer(), opts.tty);
                }
                StatusCode.exitFatal(err, err_pipe);
            };
            const child_ret = stats.read(profile_stats) catch |err|
                StatusCode.exitFatal(err, err_pipe);

            // Dump information on the IPC pipe
            std.zon.stringify.serialize(child_ret, .{}, ipc_write.writer()) catch |err|
                StatusCode.exitFatal(err, err_pipe);

            StatusCode.exitSucess();
        },
        .parent => |ret| {
            defer ret.stdin.close();
            defer ret.ipc_write.close();
            defer ret.ipc_read.close();
            errdefer process.killPid(ret.pid, null);

            var rusage: posix.rusage = undefined;
            const term = try process.waitOnFork(
                ret.pid,
                &rusage,
                opts.timeout_ns,
            );

            const stats: ?Statistics.Ret = blk: {
                var buf: [4096]u8 = undefined;
                const amt = ret.ipc_read.read(&buf) catch break :blk null;

                // -1 because we need to make it sentinel terminated
                if (amt >= buf.len - 1) break :blk null;

                // HACK: ew
                buf[amt] = 0;
                const source: [:0]const u8 = @ptrCast(buf[0..amt]);

                comptime assert(!requiresAllocator(Statistics.Ret));
                break :blk std.zon.parse.fromSlice(
                    Statistics.Ret,
                    alloc,
                    source,
                    null,
                    .{},
                ) catch null;
            };

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

pub const RunOpts = struct {
    type: Type,
    filter: ?[]const u8 = null,
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
    opts: RunOpts,
    tests: []const TestInformation,
    constrs: []const ContructorInformation,
) !void {
    var logger: RunLogger = try .init(alloc, opts.prefix, opts.type, opts.dry_run);
    errdefer logger.deinit(alloc);

    // TODO: Ugly
    const filter: Filter = .init(if (opts.filter) |f| &.{f} else null, null, .{
        .type = opts.type,
        .meta = true,
    });

    std.log.info("Running up to {d} permutations", .{filter.countSurviving(tests, constrs)});
    const stderr = std.io.getStdErr();
    const stdout = std.io.getStdOut();

    var fail_count: u32 = 0;

    tests: for (tests) |test_info| {
        if (filter.filterTest(test_info)) continue :tests;

        try stdout.writer().print(
            \\ 
            \\ ==== {s} ====
            \\
        , .{
            test_info.name,
        });

        constrs: for (constrs) |constr_info| {
            if (filter.filterCombination(test_info, constr_info)) continue :constrs;

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

                const ret: StatsRet = try runOnce(alloc, constr_info.constr_fn, test_opts);

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
                    running_stats.total_time.add(stats.wall_time);
                    running_stats.total_cache_miss_percent.add(stats.perf.getCacheMissPercent() orelse 100);

                    if (stats.profile) |profile| {
                        running_stats.allocations.add(profile.allocations);
                    }
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
        if (test_chars.failing and self.opts.type != .testing) return true;

        // Whitelist
        if (self.test_whitelist) |whitelist| {
            for (whitelist) |item|
                if (std.mem.eql(u8, item, test_info.name)) return true;
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
                if (std.mem.eql(u8, item, constr_info.name)) return true;
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

const assert = std.debug.assert;

const native_os = builtin.os.tag;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ProfilingAllocator = profiling.ProfilingAllocator;
const RunLogger = @import("RunLogger.zig");
const Statistics = @import("Statistics.zig");
