pub const TestFn = *const fn (Allocator, TestArg.ArgInt) anyerror!void;

pub const TestOpts = struct {
    type: Opts.Type,

    arg: TestArg.ArgInt,

    // TODO: I don't really this being nullable
    timeout_ns: ?u64 = null,

    tty: std.io.tty.Config,
    test_fn: TestFn,
    profiling: ?*Profiling,

    pub fn zonable(self: *const @This()) Zonable {
        return .{
            .type = self.type,
            .timeout_ns = self.timeout_ns,
            .arg = self.arg,
        };
    }

    pub const Zonable = struct {
        type: Opts.Type,
        timeout_ns: ?u64,
        arg: ?usize,
    };
};

pub const TestCharacteristics = struct {
    leaks: bool = false,
    multithreaded: bool = false,
    long_running: bool = false,

    /// Avoid flaky tests if possible
    flaky: bool = false,

    /// Meta test to test the existing infrastructure
    meta: bool = false,

    /// A failing test is supposed to emit some error
    failure: Failure = .no_failure,

    testing: bool = false,

    pub const default: TestCharacteristics = .{};

    pub const Failure = union(enum) {
        no_failure,
        any_failure,
        term: process.Term,
    };

    pub fn zonable(self: TestCharacteristics) Zonable {
        return .{
            .multithreaded = self.multithreaded,
            .long_running = self.long_running,
            .flaky = self.flaky,
        };
    }

    pub const Zonable = struct {
        multithreaded: bool,
        long_running: bool,
        flaky: bool,
    };
};

pub const TestInformation = struct {
    name: []const u8,
    test_fn: TestFn,

    description: ?[]const u8 = null,
    charactaristics: TestCharacteristics = .default,
    timeout_ns: ?u64 = null,
    arg: TestArg = .none,
    rerun: Rerun = .default,

    pub fn zonable(self: @This()) Zonable {
        return .{
            .name = self.name,
            .characteristics = self.charactaristics.zonable(),
        };
    }

    pub const Zonable = struct {
        name: []const u8,
        characteristics: TestCharacteristics.Zonable,
    };
};

pub const ConstructorFn = *const fn (TestOpts) anyerror!void;

pub const ConstructorCharacteristics = struct {
    thread_safe: bool = true,
    safety: bool = false,

    pub const default = .{};
};
pub const ContructorInformation = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    characteristics: ConstructorCharacteristics,
    constr_fn: ConstructorFn,

    pub fn zonable(self: @This()) Zonable {
        return .{
            .name = self.name,
            .characteristics = self.characteristics,
        };
    }

    pub const Zonable = struct {
        name: []const u8,
        characteristics: ConstructorCharacteristics,
    };
};

// TODO: This doesn't feel it belongs in runner
pub const TestArg = union(enum) {
    pub const ArgInt = u64;

    /// The test is provided no argument.
    none,

    /// The test is provided all elements in the list one at a time.
    list: []const ArgInt,

    /// The test is provided all elements in the exclusive range
    /// [start..start + n) one at a time.
    linear: struct { start: ArgInt = 0, n: ArgInt },

    /// The test is provided all elements in the sequence
    /// [start * 2^0, start * 2^1 ... start * 2^n] one at a time.
    exponential: struct { start: ArgInt = 1, n: std.math.Log2Int(ArgInt) },

    pub fn iter(self: TestArg) Iter {
        return .{ .type = self };
    }

    pub const Iter = struct {
        type: TestArg,
        n: ArgInt = 0,

        pub fn next(self: *@This()) ?ArgInt {
            defer self.n += 1;

            return switch (self.type) {
                .none => if (self.n == 0) @as(ArgInt, undefined) else null,

                .list => |t| if (self.n < t.len) t[self.n] else null,

                .linear => |t| if (self.n < t.n) t.start + self.n else null,

                .exponential => |t| if (self.n <= t.n)
                    t.start * (@as(ArgInt, 1) << @intCast(self.n))
                else
                    null,
            };
        }
    };
};

pub const Profiling = statistics.Profiling;

pub fn run(alloc: Allocator, opts: TestOpts) !void {
    return switch (opts.type) {
        .testing, .benchmarking => try opts.test_fn(alloc, opts.arg),
        .profiling => {
            var profiler = ProfilingAllocator.init(alloc, opts.profiling.?);

            try opts.test_fn(profiler.allocator(), opts.arg);
        },
    };
}

pub const Opts = struct {
    type: Type,
    test_whitelist: ?[]const []const u8 = null,
    constr_whitelist: ?[]const []const u8 = null,
    min_runtime_ns: u64 = std.time.ns_per_s * 5,
    tty: std.io.tty.Config = .escape_codes,
    prefix: [:0]const u8 = "runs",
    dry_run: bool = false,
    quiet: bool = false,
    debug: bool = false,

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

    const filter: Filter = .init(opts.test_whitelist, opts.constr_whitelist, .{
        .type = opts.type,
        // TODO: wut?
        .meta = true,
    });

    std.log.info("Running {d} permutations", .{filter.countSurviving(tests, constrs)});

    // Minimal, single threaded, single process version of the runner
    if (opts.debug) {
        tests: for (tests) |test_info| {
            if (filter.filterTest(test_info)) continue :tests;

            var iter = test_info.arg.iter();

            while (iter.next()) |arg| {
                constrs: for (constrs) |constr_info| {
                    if (filter.filterCombination(test_info, constr_info)) continue :constrs;

                    var prof: Profiling = .init;

                    const test_opts: TestOpts = .{
                        .type = opts.type,
                        .test_fn = test_info.test_fn,
                        .timeout_ns = test_info.timeout_ns,
                        .tty = opts.tty,
                        .profiling = &prof,
                        .arg = arg,
                    };

                    const rerun: Rerun = if (opts.type == .testing)
                        .once
                    else
                        test_info.rerun;

                    const status = try rerun.runMany(
                        alloc,
                        constr_info.constr_fn,
                        test_opts,
                    );

                    switch (status) {
                        .success => {},
                        .failure => {},
                    }
                }
            }
        }
        return;
    }

    tests: for (tests) |test_info| {
        if (filter.filterTest(test_info)) continue :tests;

        const test_run = try logger.startTest(alloc, test_info);

        var iter = test_info.arg.iter();

        while (iter.next()) |arg| {
            const arg_run = try logger.startArgument(
                alloc,
                test_run,
                test_info.arg,
                arg,
            );
            defer logger.finishArgument(arg_run) catch @panic("Print failure");

            constrs: for (constrs) |constr_info| {
                if (filter.filterCombination(test_info, constr_info)) continue :constrs;

                try logger.startConstr(constr_info);

                var prof: Profiling = if (opts.type == .profiling) .init else undefined;

                const test_opts: TestOpts = .{
                    .type = opts.type,
                    .test_fn = test_info.test_fn,
                    .timeout_ns = test_info.timeout_ns,
                    .tty = opts.tty,
                    .arg = arg,
                    .profiling = if (opts.type == .profiling) &prof else null,
                };

                const rerun: Rerun = if (opts.type == .testing)
                    .once
                else
                    test_info.rerun;

                const status = try rerun.runMany(
                    alloc,
                    constr_info.constr_fn,
                    test_opts,
                );

                switch (status) {
                    .success => |current_run| {
                        switch (test_info.charactaristics.failure) {
                            .no_failure => {},
                            .any_failure, .term => {
                                try logger.runFail(null, "Success", 0);
                                continue :constrs;
                            },
                        }

                        try logger.runSuccess(
                            alloc,
                            constr_info,
                            arg_run,
                            current_run,
                            if (opts.type == .profiling) &prof else null,
                        );
                    },

                    .failure => |stats| {
                        defer stats.deinit();

                        if (stats.term == .TimedOut) {
                            try logger.runTimeout();
                            continue :constrs;
                        }

                        const reason = switch (test_info.charactaristics.failure) {
                            .no_failure => "Failed test",

                            // TODO: Call run success here somehow
                            .any_failure => {
                                try logger.testSuccess();
                                continue :constrs;
                            },
                            .term => |t| if (std.meta.eql(t, stats.term)) {
                                try logger.testSuccess();
                                continue :constrs;
                            } else "Incorrect error",
                        };

                        try logger.runFail(stats, reason, stats.term.code());
                    },
                }
            }
        }
    }
}

pub const Rerun = struct {
    run_at_least: usize,
    run_for_ns: u64,

    pub const once: Rerun = .{
        .run_at_least = 1,
        .run_for_ns = 0,
    };

    pub const default: Rerun = .{
        .run_at_least = 20,
        .run_for_ns = std.time.ns_per_s,
    };

    pub fn runMany(
        self: @This(),
        alloc: Allocator,
        constr_fn: ConstructorFn,
        test_opts: TestOpts,
    ) !union(enum) {
        success: Run,
        failure: StatsRet,
    } {
        var run_count: usize = 0;
        var timer = std.time.Timer.start() catch @panic("Must support timers");

        var current_run: Run = .init;

        while (timer.read() < self.run_for_ns or run_count < self.run_at_least) {
            defer run_count += 1;

            const ret: StatsRet = try runFork(alloc, constr_fn, test_opts);

            switch (ret.term) {
                else => return .{ .failure = ret },
                .Exited => |code| {
                    const status = StatusCode.codeToStatus(code);
                    switch (status) {
                        .success => {},
                        else => return .{ .failure = ret },
                    }
                },
            }

            defer ret.deinit();

            current_run.runs += 1;
            current_run.time.add(@floatFromInt(ret.performance.wall_time));
            current_run.cache_misses.add(ret.performance.perf.getCacheMissPercent());
            current_run.max_rss.add(@floatFromInt(ret.rusage.maxrss * 1024));

            if (test_opts.type == .profiling) {
                test_opts.profiling.?.* = ret.profiling.?;
            }
        }

        return .{ .success = current_run };
    }
};

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

fn runFork(alloc: Allocator, constr_fn: ConstructorFn, opts: TestOpts) !StatsRet {
    const ChildRet = struct {
        performance: Performance.Ret,
        profiling: ?Profiling,
    };

    // TODO: Look into making child and parent different functions
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
                .profiling = if (opts.profiling) |p| p.* else null,
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

            if (term.isFailing()) {
                return .{
                    .term = term,
                    .stdout = ret.stdout,
                    .stderr = ret.stderr,
                    .err_pipe = ret.err_pipe,
                    .rusage = rusage,
                    .performance = undefined,
                    .profiling = undefined,
                };
            }

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
                if (!std.ascii.eqlIgnoreCase(item, test_info.name)) return true;
        }

        return false;
    }

    pub fn filterCombination(self: Filter, test_info: TestInformation, constr_info: ContructorInformation) bool {
        const test_chars = test_info.charactaristics;
        const constr_chars = constr_info.characteristics;

        if (test_chars.failure != .no_failure and !constr_chars.safety) return true;

        // If the test requires multiple threads, but the allocator is single
        // threaded, skip
        if (test_chars.multithreaded and !constr_chars.thread_safe) return true;

        // If we're not running meta tests, skip them
        if (test_chars.meta and !self.opts.meta) return true;

        // Whitelist
        if (self.constr_whitelist) |whitelist| {
            for (whitelist) |item|
                if (!std.ascii.eqlIgnoreCase(item, constr_info.name)) return true;
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
