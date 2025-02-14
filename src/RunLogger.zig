runs: std.ArrayListUnmanaged(RunStats) = .empty,
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
    runs: []const RunStats = &.{},

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

pub const RunStats = struct {
    runs: Tally(u64, .counter) = .init,
    total_time: Tally(u64, .time) = .init,
    total_cache_miss_percent: Tally(f128, .percent) = .init,
    allocations: Tally(u64, .count) = .init,
    total_max_rss: Tally(u64, .memory) = .init,
};

pub const Unit = enum {
    time,
    count,
    counter,
    memory,
    percent,

    pub fn convert(unit: @This(), value: f128) struct { f128, []const u8 } {
        return switch (unit) {
            .percent => .{ value, "%" },
            .count, .counter => blk: {
                var limit: f128 = 1;
                inline for (.{ "", "K", "M", "G", "T", "P" }) |name| {
                    defer limit *= 1000;
                    assert(std.math.isNormal(limit));

                    if (value < limit * 1000) {
                        break :blk .{ value / limit, name };
                    }
                }
                break :blk .{ value / limit, "P" };
            },
            .memory => blk: {
                var limit: f128 = 1;
                inline for (.{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" }) |name| {
                    defer limit *= 1024;
                    assert(std.math.isNormal(limit));

                    if (value < limit * 1024) {
                        break :blk .{ value / limit, name };
                    }
                }
                break :blk .{ value / limit, "PiB" };
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
            if (unit == .counter) return unit.convert(self.total_value);
            if (self.count == 0) return unit.convert(0);

            const val = self.total_value / @as(f128, @floatFromInt(self.count));

            return unit.convert(val);
        }

        pub fn dump(self: @This(), prefix: []const u8, width: u16, file: File) !void {
            const count, const suffix = self.get();

            try file.writer().print("{s}:", .{prefix});

            const pad_width = width -| prefix.len -| 1;
            for (0..pad_width) |_| try file.writeAll(" ");

            try file.writer().print("{d:0>2.2}{s}\n", .{ count, suffix });
        }
    };
}

pub const Opts = struct {
    cli: bool = true,
    disk: bool = true,
    prefix: [:0]const u8 = "runs",
};

pub fn init(alloc: Allocator, typ: RunOpts.Type, opts: Opts) !Self {
    if (!opts.disk) return .{
        .opts = opts,
    };
    const type_dir_name = switch (typ) {
        .benchmarking => "bench",
        .profiling => "profile",
        .testing => "testing",
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

pub fn runSucess(self: *Self, alloc: Allocator, run_info: RunStats) !void {
    // update file _first_ to reduce the risk of losing a run
    if (self.opts.disk) try updateFile(self, alloc, run_info);

    if (!self.opts.cli) return;

    const stdout = std.io.getStdOut();

    const padding = 20;

    try run_info.runs.dump("- Runs", padding, stdout);
    try run_info.total_time.dump("- Time", padding, stdout);
    try run_info.total_max_rss.dump("- Max RSS", padding, stdout);
    try run_info.allocations.dump("- Allocations", padding, stdout);
    try run_info.total_cache_miss_percent.dump("- Cache misses", padding, stdout);
}

fn updateFile(self: *Self, alloc: Allocator, run_info: RunStats) !void {
    try self.runs.append(alloc, run_info);

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
