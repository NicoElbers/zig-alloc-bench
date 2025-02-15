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

pub const Zon = struct {
    build: Build = .{},
    runs: []const Run.Zonable = &.{},

    pub const Build = struct {
        optimization: std.builtin.OptimizeMode = buitin.mode,
        arch: std.Target.Cpu.Arch = buitin.target.cpu.arch,
        model_name: []const u8 = buitin.target.cpu.model.name,
        os: std.Target.Os.Tag = buitin.os.tag,
    };
};

pub fn zonable(self: Self) Zon {
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

pub fn startConstr(self: Self, constr_info: ContructorInformation) !void {
    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();

    try stdout.writeAll("\n");
    try printPadded('-', 30, stdout, constr_info.name);
}

fn printPadded(pad: u8, width: u16, file: File, str: []const u8) !void {
    // Always have 2 padding, looks nicer
    const pad_count = (width -| 6) -| str.len + 4;
    const pad_side = @divFloor(pad_count, 2);

    for (0..pad_side) |_| try file.writeAll(&.{pad});
    try file.writeAll(" ");
    try file.writeAll(str);
    try file.writeAll(" ");
    for (0..pad_side) |_| try file.writeAll(&.{pad});
    try file.writeAll("\n");
}

pub fn runFail(self: *Self, ret: StatsRet, reason: []const u8, code: u32) !void {
    self.fail_count += 1;

    const stderr = std.io.getStdErr();

    try dumpFile("stdout", ret.stdout, stderr);
    try dumpFile("stderr", ret.stderr, stderr);
    try dumpFile("Error", ret.err_pipe, stderr);

    try stderr.writer().print("Failed due to {s} ({d})\n", .{ reason, code });
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

pub fn runSucess(self: *Self, alloc: Allocator, run_info: *const Run) !void {
    const stdout = std.io.getStdOut();

    if (self.opts.type == .testing) {
        try stdout.writeAll("Run Sucess\n");
        return;
    }

    // update file _first_ to reduce the risk of losing a run
    if (self.opts.disk) try updateFile(self, alloc, run_info);

    if (!self.opts.cli) return;

    // FIXME: Ugly as all hell but it works for now
    // zig fmt: off
    try statistics.Unit.counter.write(stdout , "Runs                   ", @floatFromInt(run_info.runs));
    try statistics.Unit.time.write(stdout    , "Time                   ", run_info.time.p50());
    try statistics.Unit.memory.write(stdout  , "Max rss                ", run_info.max_rss.p50());
    try statistics.Unit.percent.write(stdout , "Cache misses           ", run_info.cache_miss_percent.p50());
    // zig fmt: on

    const profiling = run_info.profiling;

    if (profiling.allocations.success.p50()) |v|
        try statistics.Unit.time.write(stdout, "Successful allocations ", v);
    if (profiling.allocations.failure.p50()) |v|
        try statistics.Unit.time.write(stdout, "Failed allocations     ", v);

    if (profiling.resizes.success.p50()) |v|
        try statistics.Unit.time.write(stdout, "Sucessful resizes      ", v);
    if (profiling.resizes.failure.p50()) |v|
        try statistics.Unit.time.write(stdout, "Failed resizes         ", v);

    if (profiling.remaps.success.p50()) |v|
        try statistics.Unit.time.write(stdout, "Sucessful remaps       ", v);
    if (profiling.remaps.failure.p50()) |v|
        try statistics.Unit.time.write(stdout, "Failed remaps          ", v);

    if (profiling.frees.p50()) |v|
        try statistics.Unit.time.write(stdout, "Frees                  ", v);
}

fn updateFile(self: *Self, alloc: Allocator, run_info: *const Run) !void {
    try self.runs.append(alloc, run_info.zonable());

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
const File = std.fs.File;
const Run = statistics.Run;
