runs: std.ArrayListUnmanaged(RunStats) = .empty,
output: ?Output = null,

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
    hardware: Hardware = .{},
    runs: []const RunStats = &.{},

    pub const Hardware = struct {
        // TODO: Collect some hardware stats
    };
};

pub fn zonable(self: Self) Zon {
    return .{
        .hardware = .{},
        .runs = self.runs.items,
    };
}

pub fn init(alloc: Allocator, prefix: [:0]const u8, typ: RunOpts.Type, dry: bool) !Self {
    if (dry) return .{};

    std.fs.cwd().makeDirZ(prefix) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var base_dir = try std.fs.cwd().openDirZ(prefix, .{});
    errdefer base_dir.close();

    const type_dir_name = switch (typ) {
        .benchmarking => "bench",
        .profiling => "profile",
        .testing => "testing",
    };

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

    return .{ .output = output };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.runs.deinit(alloc);

    if (self.output) |*out| {
        out.dir.close();
        alloc.free(out.last_increment_path);
    }

    self.* = undefined;
}

pub fn update(self: *Self, alloc: Allocator, run_info: RunStats) !void {
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

    if (self.output) |*out| {
        // TODO: make the timestamp human readable
        const path = try std.fmt.allocPrintZ(alloc, "run_{d}", .{std.time.timestamp()});
        defer alloc.free(path);

        try out.dir.renameZ(out.last_increment_path, path);
    }
}

const std = @import("std");
const runner = @import("runner.zig");

const Allocator = std.mem.Allocator;
// FIXME: This module should probably not depend on the runner, the other
// way around feels better, but then I don't clearly see how I get RunStats in here
// rethink this when the entire codebase is in a better state.
// - An idea maybe is to have configuration be it's own module, which defines both
//   these
const RunStats = runner.RunStats;
const RunOpts = runner.Opts;
