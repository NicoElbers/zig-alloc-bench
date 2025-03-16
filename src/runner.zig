pub const TestFn = *const fn (Allocator, TestArg.ArgInt) anyerror!void;

pub const TestOpts = struct {
    type: Config.Type,

    arg: TestArg.ArgInt,

    timeout_ns: u64,

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
        type: Config.Type,
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

    pub const multi_threaded: TestCharacteristics = .{
        .multithreaded = true,
    };

    pub const Failure = union(enum) {
        no_failure,
        any_failure,
        err: anyerror,

        pub fn equals(self: Failure, err: anyerror) bool {
            return switch (self) {
                .no_failure => false,
                .any_failure => true,
                .err => |e| e == err,
            };
        }
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
    timeout_ns: u64 = std.time.ns_per_s,
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

    pub const default: ConstructorCharacteristics = .{};
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

pub fn run(alloc: Allocator, opts: TestOpts) !void {
    return switch (opts.type) {
        .testing, .benchmarking => try opts.test_fn(alloc, opts.arg),
        .profiling => {
            var profiler = ProfilingAllocator.init(alloc, opts.profiling.?);

            try opts.test_fn(profiler.allocator(), opts.arg);
        },
    };
}

pub const Config = struct {
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
    opts: Config,
) !void {
    const filter: Filter = .init(opts.test_whitelist, opts.constr_whitelist, .{
        .type = opts.type,
    });

    std.log.info("Running {d} permutations", .{filter.countSurviving(tests, constrs)});

    var logger: RunLogger = try .init(alloc, .{
        .type = opts.type,
        .cli = !opts.quiet,
        .disk = !opts.dry_run,
        .prefix = opts.prefix,
    });
    defer logger.finish(alloc) catch |err| @panic(@errorName(err));

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

                var current_run: Run = .init;

                // FIXME: ew
                var tmp: Profiling = .init;

                const test_opts: TestOpts = .{
                    .type = opts.type,
                    .test_fn = test_info.test_fn,
                    .timeout_ns = test_info.timeout_ns,
                    .tty = opts.tty,
                    .arg = arg,
                    .profiling = if (opts.type == .profiling) &tmp else null,
                };

                const rerun: Rerun = if (opts.type == .testing)
                    .once
                else
                    test_info.rerun;

                const status = try rerun.runMany(
                    alloc,
                    constr_info.constr_fn,
                    test_opts,
                    &current_run,
                );

                switch (status) {
                    .success => |prof| {
                        switch (test_info.charactaristics.failure) {
                            .no_failure => {},
                            .any_failure, .err => {
                                try logger.runFail("Success", 0);
                                continue :constrs;
                            },
                        }

                        try logger.runSuccess(
                            alloc,
                            constr_info,
                            arg_run,
                            &current_run,
                            prof,
                        );
                    },

                    .failure => |stats| {
                        defer stats.deinit();

                        const stderr = std.io.getStdErr();

                        if (stats.term == .TimedOut) {
                            try logger.runTimeout();
                            try dumpFile("stdout", stats.stdout, stderr);
                            try dumpFile("stderr", stats.stderr, stderr);
                            try dumpFile("Error", stats.err_pipe, stderr);
                            continue :constrs;
                        }

                        const reason = switch (test_info.charactaristics.failure) {
                            .no_failure => "Failed test",

                            .any_failure => {
                                try logger.testSuccess();
                                continue :constrs;
                            },
                            .err => |e| if (StatusCode.toStatus(e) !=
                                StatusCode.codeToStatus(@truncate(stats.term.code())))
                            {
                                try logger.testSuccess();
                                continue :constrs;
                            } else "Incorrect error",
                        };

                        try logger.runFail(reason, stats.term.code());
                        try dumpFile("stdout", stats.stdout, stderr);
                        try dumpFile("stderr", stats.stderr, stderr);
                        try dumpFile("Error", stats.err_pipe, stderr);
                    },
                }
            }
        }
    }
}

pub const Run = struct {
    runs: usize = 0,
    time: Tally = .init,
    max_rss: Tally = .init,
    cache_misses: Tally = .init,

    pub fn zonable(self: *Run) Zonable {
        return .{
            .runs = self.runs,
            .time = self.time.zonable(),
            .max_rss = self.max_rss.zonable(),
            .cache_misses = self.cache_misses.zonable(),
        };
    }

    pub const Zonable = struct {
        runs: usize,
        time: Tally.Zonable,
        max_rss: Tally.Zonable,
        cache_misses: Tally.Zonable,
    };

    pub const init: Run = .{};
};

pub const Rerun = struct {
    run_at_least: usize,
    run_for_ns: u64,

    pub const once: Rerun = .{
        .run_at_least = 1,
        .run_for_ns = 0,
    };

    pub const default: Rerun = .{
        .run_at_least = 5,
        .run_for_ns = std.time.ns_per_s,
    };

    pub fn runMany(
        self: @This(),
        alloc: Allocator,
        constr_fn: ConstructorFn,
        test_opts: TestOpts,
        current_run: *Run,
    ) !union(enum) {
        success: ?Profiling.Zonable,
        failure: StatsRet,
    } {
        var prof: ?Profiling.Zonable = if (test_opts.profiling) |_| .init else null;
        var run_count: usize = 0;
        var timer = std.time.Timer.start() catch @panic("Must support timers");

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

            if (test_opts.type != .testing) {
                current_run.runs += 1;
                current_run.time.add(@floatFromInt(ret.performance.wall_time));
                current_run.cache_misses.add(ret.performance.perf.getCacheMissPercent());
                current_run.max_rss.add(@floatFromInt(ret.rusage.maxrss * 1024));

                if (prof) |*p| {
                    p.add(ret.profiling.?);
                }
            }
        }

        if (prof) |*p| blk: {
            if (run_count == 0) break :blk;

            p.div(@floatFromInt(run_count));
        }

        return .{ .success = prof };
    }
};

pub const StatsRet = struct {
    term: process.Term,
    stdout: File,
    stderr: File,
    err_pipe: File,
    rusage: posix.rusage,
    performance: Performance.Ret,
    profiling: ?Profiling.Zonable,

    pub fn deinit(self: @This()) void {
        self.err_pipe.close();
        self.stderr.close();
        self.stdout.close();
    }
};

fn runFork(alloc: Allocator, constr_fn: ConstructorFn, opts: TestOpts) !StatsRet {
    return switch (try process.fork()) {
        .child => |files| runChild(constr_fn, files, opts),
        .parent => |child| runParent(alloc, child, opts),
    };
}

const ChildRet = struct {
    performance: Performance.Ret,
    profiling: ?Profiling.Zonable,
};

fn runChild(
    constr_fn: ConstructorFn,
    files: process.ForkRetChild,
    opts: TestOpts,
) noreturn {
    const err_pipe = files.err_pipe;
    const ipc_write = files.ipc_write;
    // const ipc_read = fork.ipc_read;

    var stats = Performance.init() catch |err|
        StatusCode.exitFatal(err, err_pipe);

    constr_fn(opts) catch |err| {
        if (@errorReturnTrace()) |st| {
            process.dumpStackTrace(st.*, err_pipe.writer(), opts.tty);
        }
        StatusCode.exitFatal(err, err_pipe);
    };

    const perf = stats.read() catch |err|
        StatusCode.exitFatal(err, err_pipe);
    stats.deinit();

    const child_ret: ChildRet = .{
        .performance = perf,
        .profiling = if (opts.profiling) |p| p.zonable() else null,
    };

    // Dump information on the IPC pipe
    @setEvalBranchQuota(2000);
    std.zon.stringify.serialize(child_ret, .{ .whitespace = false }, ipc_write.writer()) catch |err|
        StatusCode.exitFatal(err, err_pipe);

    StatusCode.exitSucess();
}

fn runParent(alloc: Allocator, child: process.ForkRetParent, opts: TestOpts) !StatsRet {
    defer child.stdin.close();
    defer child.ipc_read.close();

    var rusage: posix.rusage = undefined;
    const term = try process.waitOnFork(
        child.pid,
        &rusage,
        opts.timeout_ns,
    );

    if (term.isFailing()) {
        return .{
            .term = term,
            .stdout = child.stdout,
            .stderr = child.stderr,
            .err_pipe = child.err_pipe,
            .rusage = rusage,
            .performance = undefined,
            .profiling = undefined,
        };
    }

    const stats: ChildRet = if (opts.type == .testing)
        undefined
    else blk: {
        var buf: [1024]u8 = undefined;
        const amt = try child.ipc_read.read(&buf);

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
        .stdout = child.stdout,
        .stderr = child.stderr,
        .err_pipe = child.err_pipe,
        .rusage = rusage,
        .performance = stats.performance,
        .profiling = stats.profiling,
    };
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
    type: Config.Type,
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
        if (self.test_whitelist) |whitelist| blk: {
            for (whitelist) |item| {
                if (std.ascii.eqlIgnoreCase(item, test_info.name))
                    break :blk;
            }
            return true;
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

        // Whitelist
        if (self.constr_whitelist) |whitelist| blk: {
            for (whitelist) |item| {
                if (std.ascii.eqlIgnoreCase(item, constr_info.name))
                    break :blk;
            }
            return true;
        }

        return false;
    }
};

fn dumpFile(file_name: []const u8, read: File, write: File) !void {
    const color = std.io.tty.detectConfig(write);
    const writer = write.writer();

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
            try color.setColor(writer, .bold);
            try writer.print("----- {s} ----\n", .{file_name});
            try color.setColor(writer, .reset);
        }

        try writer.writeAll(buf[0..amt]);
    }

    if (written_anything) {
        try color.setColor(writer, .bold);
        try writer.print("----- {s} ----\n\n", .{file_name});
        try color.setColor(writer, .reset);
    }
}

const std = @import("std");
const posix = std.posix;
const profiling = @import("profiling.zig");
const process = @import("process.zig");
const statistics = @import("statistics.zig");

const assert = std.debug.assert;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ProfilingAllocator = profiling.ProfilingAllocator;
const RunLogger = @import("RunLogger.zig");
const Performance = @import("Performance.zig");
const StatusCode = process.StatusCode;
const Tally = statistics.Tally;
const Profiling = profiling.Profiling;
