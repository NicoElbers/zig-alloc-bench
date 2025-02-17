pub const TestFn = *const fn (Allocator, TestArg.ArgInt) anyerror!void;

pub const TestArg = union(enum) {
    pub const ArgInt = u64;

    /// The test is provided no argument.
    none,

    /// The test is provided all elements in the list one at a time.
    list: []const ArgInt,

    /// The test is provided all elements in the exclusive range
    /// [start..start + n) one at a time.
    linear: struct { start: ArgInt, n: ArgInt },

    /// The test is provided all elements in the sequence
    /// [start * 2^0, start * 2^1 ... start * 2^n) one at a time.
    exponential: struct { start: ArgInt, n: std.math.Log2Int(ArgInt) },

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

                .linear => |t| if (self.n < t.n) t.start + t.n else null,

                .exponential => |t| if (self.n < t.n) t.start + 1 << t.n else null,
            };
        }
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
    failing: ?Failure = null,

    testing: bool = false,

    pub const default: TestCharacteristics = .{};

    pub const Failure = union(enum) {
        any_failure,
        term: process.Term,
    };

    pub fn zonable(self: TestCharacteristics) Zonable {
        return .{
            .multithreaded = self.multithreaded,
            .long_running = self.long_running,
            .flaky = self.flaky,
            .failing = self.failing,
        };
    }

    pub const Zonable = struct {
        multithreaded: bool,
        long_running: bool,
        flaky: bool,
        failing: ?Failure,
    };
};

pub const TestInformation = struct {
    name: []const u8,
    test_fn: TestFn,

    description: ?[]const u8 = null,
    charactaristics: TestCharacteristics = .default,
    timeout_ns: ?u64 = null,
    arg: TestArg = .none,

    pub fn zonable(self: @This()) Zonable {
        return .{
            .name = self.name,
            .test_arg = self.arg,
            .characteristics = self.charactaristics.zonable(),
        };
    }

    pub const Zonable = struct {
        name: []const u8,
        arg: TestArg,
        characteristics: TestCharacteristics.Zonable,
    };
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

    pub fn zonable(self: @This()) Zonable {
        return .{
            .name = self.name,
            .characteristics = self.characteristics,
        };
    }

    pub const Zonable = struct {
        name: []const u8,
        characteristics: AllocatorCharacteristics,
    };
};

pub const TestOpts = struct {
    type: Opts.Type,

    // TODO: I don't really like nullables in here
    arg: TestArg.ArgInt,
    timeout_ns: ?u64 = null,

    tty: std.io.tty.Config,
    test_fn: TestFn,
    profiling: *Profiling,

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

pub const Profiling = statistics.Profiling;

pub fn run(alloc: Allocator, opts: TestOpts) !void {
    return switch (opts.type) {
        .testing, .benchmarking => try opts.test_fn(alloc, opts.arg),
        .profiling => {
            var profiler = ProfilingAllocator.init(alloc, opts.profiling);

            try opts.test_fn(profiler.allocator(), opts.arg);
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

            // FIXME: Union
            if (term != .Exited or term.Exited != 0) {
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

pub const Opts = struct {
    type: Type,
    filter: ?[]const u8 = null,
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

    // TODO: Ugly
    const filter: Filter = .init(if (opts.filter) |f| &.{f} else null, null, .{
        .type = opts.type,
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

                    try constr_info.constr_fn(test_opts);
                }
            }
        }
        return;
    }

    tests: for (tests) |test_info| {
        if (filter.filterTest(test_info)) continue :tests;

        try logger.startTest(test_info);

        var iter = test_info.arg.iter();

        while (iter.next()) |arg| {
            try logger.startArgument(test_info.arg, arg);

            var first: ?struct {
                run: Run,
                prof: Profiling,
            } = null;

            constrs: for (constrs) |constr_info| {
                if (filter.filterCombination(test_info, constr_info)) continue :constrs;

                try logger.startConstr(constr_info);

                var current_run: Run = .init;

                var prof: Profiling = if (opts.type == .profiling) .init else undefined;

                const test_opts: TestOpts = .{
                    .type = opts.type,
                    .test_fn = test_info.test_fn,
                    .timeout_ns = test_info.timeout_ns,
                    .tty = opts.tty,
                    .arg = arg,
                    .profiling = &prof,
                };

                // TODO: This feels icky
                const runtime: u64 = if (opts.type == .testing)
                    0
                else
                    opts.min_runtime_ns;

                // TODO: This should be in option for the test
                var ran_once = false;
                var any_failed = false;
                var timer = std.time.Timer.start() catch unreachable;
                while (timer.read() < runtime or !ran_once) {
                    defer ran_once = true;

                    const ret: StatsRet = try runOnce(alloc, constr_info.constr_fn, test_opts);
                    defer ret.deinit();

                    switch (ret.term) {
                        inline else => |v, t| {
                            if (test_info.charactaristics.failing) |f|
                                switch (f) {
                                    .any_failure => {},
                                    .term => |term| if (term != t or @field(term, @tagName(t)) != v) {
                                        try logger.runFail(ret, @tagName(t), if (@TypeOf(v) == void) 0 else v);
                                        if (opts.type != .testing) return;
                                        any_failed = true;
                                        break;
                                    },
                                }
                            else {
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
                                    if (test_info.charactaristics.failing) |_| {
                                        try logger.runFail(ret, "Succeeded failing test", code);
                                        if (opts.type != .testing) return;
                                        any_failed = true;
                                        break;
                                    }
                                },
                                inline else => |t| {
                                    if (test_info.charactaristics.failing) |f| switch (f) {
                                        .any_failure => {},
                                        .term => |term| if (term != .Exited or term.Exited != code) {
                                            try logger.runFail(ret, "Incorrect failure exited", code);
                                            if (opts.type != .testing) return;
                                            any_failed = true;
                                            break;
                                        },
                                    } else {
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
                    current_run.cache_misses.add(ret.performance.perf.getCacheMissPercent());
                    current_run.max_rss.add(@floatFromInt(ret.rusage.maxrss * 1024));
                    if (opts.type == .profiling) {
                        prof = ret.profiling.?;
                    }
                }

                if (!any_failed) {
                    if (first) |f| {
                        try logger.runSucess(
                            alloc,
                            f.run,
                            &f.prof,
                            current_run,
                            test_opts,
                            &prof,
                        );
                    } else {
                        try logger.runSucess(
                            alloc,
                            null,
                            null,
                            current_run,
                            test_opts,
                            &prof,
                        );
                        first = .{
                            .run = current_run,
                            .prof = prof,
                        };
                    }
                }
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
