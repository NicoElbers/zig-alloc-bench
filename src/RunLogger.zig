test_runs: std.ArrayListUnmanaged(TestRun) = .empty,
output: ?Output = null,
fail_count: u32 = 0,
opts: Opts,

const Self = @This();

pub const TestRun = struct {
    test_info: TestInformation.Zonable,
    args: std.ArrayListUnmanaged(ArgRun) = .empty,

    pub fn deinit(self: *TestRun, alloc: Allocator) void {
        for (self.args.items) |*arg| {
            arg.deinit(alloc);
        }
        self.args.deinit(alloc);

        self.* = undefined;
    }

    pub fn zonable(self: TestRun, alloc: Allocator) !TestRun.Zonable {
        const args = try alloc.alloc(ArgRun.Zonable, self.args.items.len);

        for (self.args.items, 0..) |arg, i| {
            args[i] = arg.zonable();
        }

        return .{
            .test_info = self.test_info,
            .args = args,
        };
    }

    pub const Zonable = struct {
        test_info: TestInformation.Zonable,
        args: []const ArgRun.Zonable,
    };
};

pub const ArgRun = struct {
    arg: ?TestArg.ArgInt,
    constrs: std.ArrayListUnmanaged(ConstrRun) = .empty,

    pub fn deinit(self: *ArgRun, alloc: Allocator) void {
        self.constrs.deinit(alloc);

        self.* = undefined;
    }

    pub fn zonable(self: ArgRun) ArgRun.Zonable {
        return .{
            .arg = self.arg,
            .constrs = self.constrs.items,
        };
    }

    pub const Zonable = struct {
        arg: ?TestArg.ArgInt,
        constrs: []const ConstrRun,
    };
};
pub const ConstrRun = struct {
    constr_info: ContructorInformation.Zonable,
    run: Run.Zonable,
};
pub const Output = struct {
    dir: std.fs.Dir,
    last_increment_path: [:0]const u8,
    count: u64 = 0,

    pub fn incrementName(out: *Output, alloc: Allocator) ![:0]const u8 {
        defer out.count += 1;
        const path = try std.fmt.allocPrintZ(alloc, "increment_{d}-{d}", .{ std.time.timestamp(), out.count });
        return path;
    }
};

pub fn zonable(self: *const Self, alloc: Allocator) !Zonable {
    const test_runs = try alloc.alloc(TestRun.Zonable, self.test_runs.items.len);

    for (self.test_runs.items, 0..) |arg, i| {
        test_runs[i] = try arg.zonable(alloc);
    }

    return .{
        .build = .{},
        .test_runs = test_runs,
    };
}

pub const Zonable = struct {
    build: Build,
    test_runs: []const TestRun.Zonable,

    pub const Build = struct {
        optimization: std.builtin.OptimizeMode = buitin.mode,
        arch: std.Target.Cpu.Arch = buitin.target.cpu.arch,
        model_name: []const u8 = buitin.target.cpu.model.name,
        os: std.Target.Os.Tag = buitin.os.tag,
    };
};

pub const Opts = struct {
    cli: bool = true,
    disk: bool = true,
    prefix: [:0]const u8 = "runs",
    type: RunOpts.Type,
};

pub fn init(alloc: Allocator, opts: Opts) !Self {
    if (!opts.disk or opts.type == .testing) return .{
        .opts = opts,
    };

    const type_dir_name = switch (opts.type) {
        .benchmarking => "bench",
        .profiling => "profile",
        .testing => unreachable,
    };

    std.fs.cwd().makeDirZ(opts.prefix) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var base_dir = try std.fs.cwd().openDirZ(opts.prefix, .{});
    defer base_dir.close();

    base_dir.makeDirZ(type_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var type_dir = try base_dir.openDirZ(type_dir_name, .{});
    errdefer type_dir.close();

    var output: Output = .{
        .dir = type_dir,
        .last_increment_path = "",
        .count = 0,
    };

    const path = try output.incrementName(alloc);
    errdefer alloc.free(path);

    const file = try type_dir.createFileZ(path, .{ .exclusive = true });
    file.close();

    output.last_increment_path = path;

    return .{ .output = output, .opts = opts };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    for (self.test_runs.items) |*test_run|
        test_run.deinit(alloc);
    self.test_runs.deinit(alloc);

    if (self.output) |*out| {
        out.dir.close();
        alloc.free(out.last_increment_path);
    }

    self.* = undefined;
}

// TODO: Maybe print characteristics here in the future
pub fn startTest(self: *Self, alloc: Allocator, test_info: TestInformation) !*TestRun {
    if (self.opts.cli) {
        const stdout = std.io.getStdOut();

        try stdout.writeAll("\n");
        try stdout.writeAll("\n");
        try printPadded('=', 50, stdout, test_info.name);
    }

    try self.test_runs.append(alloc, .{ .test_info = test_info.zonable() });
    return &self.test_runs.items[self.test_runs.items.len - 1];
}

const test_line_width = 30;

pub fn startArgument(self: Self, alloc: Allocator, test_run: *TestRun, typ: TestArg, arg: TestArg.ArgInt) !*ArgRun {
    if (typ == .none) {
        try test_run.args.append(alloc, .{ .arg = null });
        return &test_run.args.items[test_run.args.items.len - 1];
    }

    if (self.opts.cli) {
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();
        const color = std.io.tty.detectConfig(stdout);

        const arg_str = @tagName(typ);

        const mid_len = std.fmt.count(" {s}: {d} ", .{ arg_str, arg });
        const pad_sides = (test_line_width - mid_len) / 2;

        try color.setColor(writer, .dim);
        try writer.writeAll("\n");
        try writer.writeByteNTimes('-', pad_sides);

        try writer.writeAll(" ");
        try writer.writeAll(arg_str);
        try writer.writeAll(": ");
        try color.setColor(writer, .reset);
        try color.setColor(writer, .cyan);
        try writer.print("{d}", .{arg});
        try writer.writeAll(" ");
        try color.setColor(writer, .reset);

        try color.setColor(writer, .dim);
        try writer.writeByteNTimes('-', pad_sides);
        try writer.writeAll("\n");
        try color.setColor(writer, .reset);
    }

    try test_run.args.append(alloc, .{ .arg = arg });
    return &test_run.args.items[test_run.args.items.len - 1];
}

// Joined from https://github.com/ziglang/zig/pull/22369
fn termWidth(file: File) error{ NotATerminal, Unexpected }!struct { rows: u16, columns: u16 } {
    const native_os = @import("builtin").os.tag;
    const windows = std.os.windows;
    const posix = std.posix;

    if (native_os == .windows) {
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(file.handle, &info) != windows.FALSE) {
            // In the old Windows console, info.dwSize.Y is the line count of the
            // entire scrollback buffer, so we use this instead so that we
            // always get the size of the screen.
            const screen_height = info.srWindow.Bottom - info.srWindow.Top;
            return .{
                .rows = @intCast(screen_height),
                .columns = @intCast(info.dwSize.X),
            };
        } else {
            return error.NotATerminal;
        }
    } else {
        var winsize: posix.winsize = undefined;
        return switch (posix.errno(posix.system.ioctl(file.handle, posix.T.IOCGWINSZ, @intFromPtr(&winsize)))) {
            .SUCCESS => .{ .rows = winsize.row, .columns = winsize.col },
            .NOTTY => error.NotATerminal,
            .BADF, .FAULT, .INVAL => unreachable,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

pub fn ChunkIter(comptime T: type) type {
    return struct {
        arr: []const T,
        idx: usize,
        width: usize,

        pub fn next(self: *@This()) ?[]const T {
            if (self.idx >= self.arr.len) return null;

            defer self.idx += self.width;
            return self.arr[self.idx..@min(self.idx + self.width, self.arr.len)];
        }
    };
}

const prefix_len = " cache_misses |".len;
const tally_len = 24;

pub fn finishArgument(self: *const Self, arg_run: *ArgRun) !void {
    if (self.opts.type == .testing) return;
    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();

    const term_size = try termWidth(stdout);
    const tallies_per_row = (term_size.columns - prefix_len) / tally_len;

    // const first_run = arg_run.constrs.items[0];

    var iter: ChunkIter(ConstrRun) = .{
        .arr = arg_run.constrs.items,
        .idx = 0,
        .width = tallies_per_row,
    };

    while (iter.next()) |chunk| {
        try self.logChunk(arg_run.constrs.items[0], chunk);
    }
    try writer.writeAll("\n");

    // TODO: Log entire argrun
}

fn logChunk(self: *const Self, first_run: ConstrRun, chunk: []const ConstrRun) !void {
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    const color = std.io.tty.detectConfig(stdout);

    _ = self;

    const first = first_run;

    try writer.writeAll("\n");
    {
        var counter = std.io.countingWriter(writer);
        const inner_writer = counter.writer();

        try color.setColor(writer, .dim);
        try inner_writer.writeAll(" name");
        try writer.writeByteNTimes(' ', prefix_len - counter.bytes_written - 1);
        try writer.writeAll("|");
        try color.setColor(writer, .reset);
    }

    // Allocator names
    {
        var counter = std.io.countingWriter(writer);
        const inner_writer = counter.writer();

        for (chunk) |run| {
            try inner_writer.print(" {s}", .{run.constr_info.name});
            try inner_writer.writeByteNTimes(' ', tally_len - 1 - run.constr_info.name.len);

            try color.setColor(writer, .dim);
            try inner_writer.writeAll("|");
            try color.setColor(writer, .reset);
        }
        try writer.writeAll("\n");
    }

    inline for (.{
        "time",
        "max_rss",
        "cache_misses",
    }) |tally_name| {
        const first_tally = @field(first.run, tally_name);

        // Seperating line
        {
            try color.setColor(writer, .dim);
            try writer.writeByteNTimes('-', prefix_len - 1);
            try writer.writeAll("+");

            for (chunk) |_| {
                try writer.writeByteNTimes('-', tally_len);
                try writer.writeAll("+");
            }
            try writer.writeAll("\n");
        }

        // prefix
        {
            var counter = std.io.countingWriter(writer);
            const inner_writer = counter.writer();

            try color.setColor(writer, .dim);
            try inner_writer.writeAll(" ");
            try inner_writer.writeAll(tally_name);

            try writer.writeByteNTimes(' ', prefix_len - counter.bytes_written - 1);
            try writer.writeAll("|");

            for (chunk) |_| {
                try writer.writeByteNTimes(' ', tally_len);
                try writer.writeAll("|");
            }
            try writer.writeAll("\n");
        }

        // Seperating line
        {
            try color.setColor(writer, .dim);
            try writer.writeByteNTimes('-', prefix_len - 1);
            try writer.writeAll("+");

            for (chunk) |_| {
                try writer.writeByteNTimes('-', tally_len);
                try writer.writeAll("+");
            }
            try writer.writeAll("\n");
        }

        inline for (.{
            "min",
            "p50",
            "p90",
            "p99",
            "max",
        }) |field| {
            const unit: Unit = .time;

            const first_v = @field(first_tally, field);

            for (chunk, 0..) |run, i| {
                const tally = @field(run.run, tally_name);

                // prefix
                if (i == 0) {
                    var counter = std.io.countingWriter(writer);
                    const inner_writer = counter.writer();

                    try color.setColor(writer, .dim);
                    try inner_writer.writeAll(" ");
                    try inner_writer.writeAll(field);

                    try writer.writeByteNTimes(' ', prefix_len - counter.bytes_written - 1);
                    try writer.writeAll("|");
                    try color.setColor(writer, .reset);
                }

                var counter = std.io.countingWriter(writer);
                const inner_writer = counter.writer();

                const current_v = @field(tally, field);

                // Actual value
                {
                    const value, const suffix = unit.convert(@field(run.run.time, field));

                    try color.setColor(writer, .green);
                    try inner_writer.print(" {d: >6.2} ", .{value});
                    try color.setColor(writer, .reset);
                    try color.setColor(writer, .dim);
                    try inner_writer.writeAll(&suffix);
                    try color.setColor(writer, .reset);
                }

                try inner_writer.writeByteNTimes(' ', 2);

                // Delta
                {
                    const percent = ((current_v - first_v) / first_v) * 100;
                    const value, const suffix = Unit.percent.convert(@abs(percent));

                    try color.setColor(writer, if (percent < -1)
                        .bright_green
                    else if (percent > 1)
                        .bright_red
                    else
                        .dim);
                    try inner_writer.writeAll(if (percent < 0) "-" else "+");
                    try inner_writer.print("{d: >6.2} ", .{value});
                    try inner_writer.writeAll(suffix[0..1]);
                    try color.setColor(writer, .reset);
                }

                try inner_writer.writeByteNTimes(' ', tally_len -| counter.bytes_written);

                try color.setColor(writer, .dim);
                try writer.writeAll("|");
                try color.setColor(writer, .reset);
            }
            try writer.writeAll("\n");
        }
    }

    try writer.writeAll("\n");
}

pub fn startConstr(self: Self, constr_info: ContructorInformation) !void {
    if (self.opts.cli) {
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();
        const color = std.io.tty.detectConfig(stdout);

        const len = std.fmt.count("{s} ", .{constr_info.name});

        try color.setColor(writer, .dim);
        try writer.print("{s} ", .{constr_info.name});
        try writer.writeByteNTimes(' ', 20 - len);
        try color.setColor(writer, .reset);
    }
}

fn printPadded(pad: u8, width: u16, file: File, str: []const u8) !void {
    const writer = file.writer();

    // Always have 2 padding, looks nicer
    const pad_count = (width -| 6) -| str.len + 4;
    const pad_side = @divFloor(pad_count, 2);

    const color = std.io.tty.detectConfig(file);

    try color.setColor(writer, .bold);
    try writer.writeByteNTimes(pad, pad_side);
    try file.writeAll(" ");
    try file.writeAll(str);
    try file.writeAll(" ");
    try writer.writeByteNTimes(pad, pad_side);
    try file.writeAll("\n");
    try color.setColor(writer, .reset);
}

pub fn runFail(self: *Self, ret: ?StatsRet, reason: []const u8, code: u32) !void {
    self.fail_count += 1;

    const stderr = std.io.getStdErr();
    const color = std.io.tty.detectConfig(stderr);
    const writer = stderr.writer();

    try color.setColor(writer, .red);
    try writer.print("Failure\n", .{});
    try color.setColor(writer, .reset);

    if (ret) |r| {
        try dumpFile("stdout", r.stdout, stderr);
        try dumpFile("stderr", r.stderr, stderr);
        try dumpFile("Error", r.err_pipe, stderr);
    }

    try color.setColor(writer, .red);
    try writer.print("Failed due to {s} ({d})\n", .{ reason, code });
    try color.setColor(writer, .reset);
}

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

pub fn runSuccess(
    self: *Self,
    alloc: Allocator,
    constr_info: ContructorInformation,
    arg_run: *ArgRun,
    run_info: Run,
    prof: ?*const Profiling,
) !void {
    try arg_run.constrs.append(alloc, .{
        .constr_info = constr_info.zonable(),
        .run = run_info.zonable(prof),
    });

    if (self.opts.disk) try updateFile(self, alloc);

    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();
    const color = std.io.tty.detectConfig(stdout);
    const writer = stdout.writer();

    try color.setColor(writer, .green);
    try writer.print("Success ({d})\n", .{run_info.runs});
    try color.setColor(writer, .reset);
}

fn updateFile(self: *Self, alloc: Allocator) !void {
    if (self.output) |*out| {
        const path = try out.incrementName(alloc);
        errdefer alloc.free(path);

        const new_increment = try out.dir.createFileZ(path, .{ .exclusive = true });
        defer new_increment.close();

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        @setEvalBranchQuota(2000);
        try std.zon.stringify.serialize(try self.zonable(arena.allocator()), .{}, new_increment.writer());
        try new_increment.sync(); // Ensure our new increment is written to disk

        // At this stage we know our new increment is fully written, we can delete the old one
        try out.dir.deleteFileZ(out.last_increment_path);
        alloc.free(out.last_increment_path);
        out.last_increment_path = path;
    }
}

pub fn finish(self: *Self, alloc: Allocator) !void {
    defer self.deinit(alloc);

    if (self.fail_count == 0) {
        if (self.output) |*out| {
            // TODO: make the timestamp human readable
            const path = try std.fmt.allocPrintZ(alloc, "run_{d}.zon", .{std.time.timestamp()});
            defer alloc.free(path);

            try out.dir.renameZ(out.last_increment_path, path);
        }
    } else {
        const stderr = std.io.getStdErr();

        try stderr.writer().print("Failed {d} permutations\n", .{self.fail_count});

        if (self.output) |*out| {
            // TODO: make the timestamp human readable
            const path = try std.fmt.allocPrintZ(alloc, "failed_run_{d}.zon", .{std.time.timestamp()});
            defer alloc.free(path);

            try out.dir.renameZ(out.last_increment_path, path);
        }
    }
}

const std = @import("std");
const buitin = @import("builtin");
const runner = @import("runner.zig");
const statistics = @import("statistics.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
// FIXME: This module should probably not depend on the runner, the other
// way around feels better, but then I don't clearly see how I get RunStats in here
// rethink this when the entire codebase is in a better state.
// - An idea maybe is to have configuration be it's own module, which defines both
//   these
const RunOpts = runner.Opts;
const TestInformation = runner.TestInformation;
const ContructorInformation = runner.ContructorInformation;
const StatsRet = runner.StatsRet;
const TestArg = runner.TestArg;
const Profiling = runner.Profiling;
const TestOpts = runner.TestOpts;
const File = std.fs.File;
const Run = statistics.Run;
const Tally = statistics.Tally;
const Unit = statistics.Unit;
