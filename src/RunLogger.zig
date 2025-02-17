runs: std.ArrayListUnmanaged(Run.Zonable) = .empty,
output: ?Output = null,
fail_count: u32 = 0,
opts: Opts,

const Self = @This();

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

pub const Zonable = struct {
    build: Build = .{},
    runs: []const Run.Zonable = &.{},

    pub const Build = struct {
        optimization: std.builtin.OptimizeMode = buitin.mode,
        arch: std.Target.Cpu.Arch = buitin.target.cpu.arch,
        model_name: []const u8 = buitin.target.cpu.model.name,
        os: std.Target.Os.Tag = buitin.os.tag,
    };
};

pub fn zonable(self: *const Self) Zonable {
    return .{
        .build = .{},
        .runs = self.runs.items,
    };
}

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
    self.runs.deinit(alloc);

    if (self.output) |*out| {
        out.dir.close();
        alloc.free(out.last_increment_path);
    }

    self.* = undefined;
}

// TODO: Maybe print characteristics here in the future
pub fn startTest(self: Self, test_info: TestInformation) !void {
    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();

    try stdout.writeAll("\n");
    try stdout.writeAll("\n");
    try printPadded('=', 50, stdout, test_info.name);
}

pub fn startArgument(self: Self, typ: TestArg, arg: TestArg.ArgInt) !void {
    if (!self.opts.cli) return;
    if (typ == .none) return;

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    const color = std.io.tty.detectConfig(stdout);

    try writer.writeAll("\n");
    try color.setColor(writer, .dim);
    try writer.writeByteNTimes('-', 15);
    try writer.writeAll("\n");

    try writer.writeByteNTimes(' ', 3);
    try writer.writeAll(@tagName(typ));
    try writer.writeAll(": ");
    try color.setColor(writer, .reset);
    try color.setColor(writer, .cyan);
    try writer.print("{d}", .{arg});
    try color.setColor(writer, .reset);
    try writer.writeAll("\n");

    try color.setColor(writer, .dim);
    try writer.writeByteNTimes('-', 15);
    try writer.writeAll("\n");
    try color.setColor(writer, .reset);
}

pub fn startConstr(self: Self, constr_info: ContructorInformation) !void {
    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();

    try stdout.writeAll("\n");
    try printPadded('-', 30, stdout, constr_info.name);
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

pub fn runFail(self: *Self, ret: StatsRet, reason: []const u8, code: u32) !void {
    self.fail_count += 1;

    const stderr = std.io.getStdErr();
    const writer = stderr.writer();

    try dumpFile("stdout", ret.stdout, stderr);
    try dumpFile("stderr", ret.stderr, stderr);
    try dumpFile("Error", ret.err_pipe, stderr);

    const color = std.io.tty.detectConfig(stderr);
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

const Order = enum { higher_better, lower_better };
fn resultTally(
    file: File,
    comptime name: []const u8,
    order: Order,
    unit: Unit,
    tally: anytype,
    first_tally: @TypeOf(tally),
) !void {
    switch (@TypeOf(tally)) {
        Tally => {},
        statistics.LazyTally => if (tally.tally == null) return,
        statistics.FallableTally => {
            try resultTally(file, name ++ " success", order, unit, tally.success, first_tally.success);
            try resultTally(file, name ++ " failure", order, unit, tally.failure, first_tally.failure);
            return;
        },
        else => @compileLog("no"),
    }

    const color = std.io.tty.detectConfig(file);

    const writer = file.writer();

    const cli = struct {
        pub fn prefix(val: f64) []const u8 {
            return if (val > 0) "+" else if (val == 0) " " else "-";
        }

        pub fn percentClr(ord: Order, percent: f64) std.io.tty.Color {
            return if (percent > 1)
                switch (ord) {
                    .higher_better => .bright_green,
                    .lower_better => .bright_red,
                }
            else if (percent < -1)
                switch (ord) {
                    .higher_better => .bright_red,
                    .lower_better => .bright_green,
                }
            else
                .dim;
        }
    };

    const outliers = tally.getOutliers();

    try color.setColor(writer, .bold);
    try writer.writeAll("\n" ++ name ++ ": ");
    try color.setColor(writer, .reset);

    if (outliers > 10) {
        try color.setColor(writer, .bright_yellow);
    } else {
        try color.setColor(writer, .dim);
    }
    try writer.print("({d:.2} outliers)\n", .{tally.getOutliers()});
    try color.setColor(writer, .reset);

    const min_t = tally.getMin();
    const p50_t = tally.getP50();
    const p90_t = tally.getP90();
    const p99_t = tally.getP99();
    const max_t = tally.getMax();

    const min_f = first_tally.getMin();
    const p50_f = first_tally.getP50();
    const p90_f = first_tally.getP90();
    const p99_f = first_tally.getP99();
    const max_f = first_tally.getMax();

    inline for (.{
        .{ "min", min_f, min_t },
        .{ "p50", p50_f, p50_t },
        .{ "p90", p90_f, p90_t },
        .{ "p99", p99_f, p99_t },
        .{ "max", max_f, max_t },
    }) |tuple| {
        const section_name, const first, const current = tuple;

        try writer.writeAll("  ");

        try writer.writeAll(section_name);
        try color.setColor(writer, .reset);

        const name_space = 4 - section_name.len;
        try writer.writeByteNTimes(' ', name_space);
        try writer.writeAll(": ");

        {
            const value, const suffix = unit.convert(current);

            try color.setColor(writer, .green);
            try writer.print("{d: >6.2} ", .{value});
            try color.setColor(writer, .reset);
            try color.setColor(writer, .dim);
            try writer.writeAll(&suffix);
            try color.setColor(writer, .reset);
            try writer.writeAll(" ");
        }

        try writer.writeByteNTimes(' ', 5);

        {
            const percent = ((current - first) / first) * 100;
            const value, const suffix = Unit.percent.convert(@abs(percent));

            try color.setColor(writer, cli.percentClr(order, percent));
            try writer.writeAll(cli.prefix(percent));
            try writer.print("{d: >6.2} ", .{value});
            try writer.writeAll(&suffix);
            try color.setColor(writer, .reset);
            try writer.writeAll(" ");
        }

        try writer.writeAll("\n");
    }
}

pub fn runSucess(
    self: *Self,
    alloc: Allocator,
    first_run: ?Run,
    first_prof: ?*const Profiling,
    run_info: Run,
    test_opts: TestOpts,
    prof: *const Profiling,
) !void {
    const stdout = std.io.getStdOut();
    const color = std.io.tty.detectConfig(stdout);
    const writer = stdout.writer();

    if (self.opts.type == .testing) {
        try color.setColor(writer, .green);
        try writer.writeAll("Run Sucess\n");
        try color.setColor(writer, .reset);
        return;
    }

    // update file _first_ to reduce the risk of losing a run
    if (self.opts.disk) try updateFile(self, alloc, run_info, test_opts, prof);

    if (!self.opts.cli) return;

    const run_v, const runs_s = statistics.Unit.counter.convert(@floatFromInt(run_info.runs));

    try color.setColor(writer, .dim);
    try stdout.writer().print("Runs: {d:.2} {s}\n", .{ run_v, runs_s });
    try color.setColor(writer, .reset);

    const first_time = if (first_run) |fr| fr.time else run_info.time;
    const first_max_rss = if (first_run) |fr| fr.max_rss else run_info.max_rss;
    const first_cache_misses = if (first_run) |fr| fr.cache_misses else run_info.cache_misses;

    try resultTally(stdout, "Time", .lower_better, .time, run_info.time, first_time);
    try resultTally(stdout, "Max rss", .lower_better, .memory, run_info.max_rss, first_max_rss);
    try resultTally(stdout, "Cache misses", .lower_better, .percent, run_info.cache_misses, first_cache_misses);

    if (self.opts.type == .profiling) {
        const first_allocations = if (first_prof) |fp| fp.allocations else prof.allocations;
        const first_remaps = if (first_prof) |fp| fp.remaps else prof.remaps;
        const first_resizes = if (first_prof) |fp| fp.resizes else prof.resizes;
        const first_frees = if (first_prof) |fp| fp.frees else prof.frees;

        try resultTally(stdout, "Allocations", .lower_better, .time, prof.allocations, first_allocations);
        try resultTally(stdout, "Remaps", .lower_better, .time, prof.remaps, first_remaps);
        try resultTally(stdout, "Resizes", .lower_better, .time, prof.resizes, first_resizes);
        try resultTally(stdout, "Frees", .lower_better, .time, prof.frees, first_frees);
    }
}

fn updateFile(
    self: *Self,
    alloc: Allocator,
    run_info: Run,
    test_opts: TestOpts,
    prof: *const Profiling,
) !void {
    try self.runs.append(alloc, run_info.zonable(test_opts, prof));

    if (self.output) |*out| {
        const path = try out.incrementName(alloc);
        errdefer alloc.free(path);

        const new_increment = try out.dir.createFileZ(path, .{ .exclusive = true });
        defer new_increment.close();

        try std.zon.stringify.serialize(self.zonable(), .{}, new_increment.writer());
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
            const path = try std.fmt.allocPrintZ(alloc, "run_{d}", .{std.time.timestamp()});
            defer alloc.free(path);

            try out.dir.renameZ(out.last_increment_path, path);
        }
    } else {
        const stderr = std.io.getStdErr();

        try stderr.writer().print("Failed {d} permutations\n", .{self.fail_count});

        if (self.output) |*out| {
            // TODO: make the timestamp human readable
            const path = try std.fmt.allocPrintZ(alloc, "failed_run_{d}", .{std.time.timestamp()});
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
