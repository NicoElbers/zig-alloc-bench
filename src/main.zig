const test_functions: []const TestInformation = &.{
    .{
        .name = "Simple allocation",
        .test_fn = &simpleTest,
    },
    .{
        .name = "Many allocations and frees",
        .test_fn = &manyAllocFree,
    },
    .{
        .name = "Many allocations, resizes and frees",
        .timeout_ns = std.time.ns_per_s,
        .test_fn = &manyAllocResizeFree,
    },

    .{
        .name = "No free",
        .charactaristics = .{
            .failing = true,
        },
        .test_fn = &noFree,
    },
    .{
        .name = "Double free",
        .charactaristics = .{
            .failing = true,
        },
        .test_fn = &doubleFree,
    },
    .{
        .name = "Failing test",
        .description =
        \\ A meta test that always fails with the error `error.Fail`
        \\ leading to a `genericError` in status detection
        ,
        .charactaristics = .{
            .meta = true,
            .failing = true,
        },
        .test_fn = &failingTest,
    },
};

const constructor_functions: []const ContructorInformation = &.{
    .{
        .name = "Default GPA",
        .constr_fn = &simpleGpa,
    },
    .{
        .name = "Other GPA",
        .constr_fn = &otherGpa,
    },
};

fn simpleTest(alloc: Allocator) !void {
    const a = try alloc.alloc(u8, 1000);
    defer alloc.free(a);
}

fn manyAllocFree(alloc: Allocator) !void {
    for (0..10_000) |_| {
        const arr = try alloc.alloc(u32, 100);
        alloc.free(arr);
    }
}

fn manyAllocResizeFree(alloc: Allocator) !void {
    for (0..10_000) |_| {
        const arr = try alloc.alloc(u32, 100);
        // _ = alloc.resize(arr, 50);
        alloc.free(arr);
    }
}

fn oomTest(alloc: Allocator) !void {
    const buf = try alloc.alloc(u8, std.math.maxInt(usize) / 2);
    alloc.free(buf);
}

fn noFree(alloc: Allocator) !void {
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
    _ = try alloc.alloc(u64, 64);
}

fn doubleFree(alloc: Allocator) !void {
    const ptr = try alloc.create(u8);
    alloc.destroy(ptr);
    alloc.destroy(ptr);
}

fn failingTest(alloc: Allocator) !void {
    _ = alloc;
    return error.Fail;
}

fn simpleGpa(opts: runner.TestOpts) !?Statistics.Profiling {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn otherGpa(opts: runner.TestOpts) !?Statistics.Profiling {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .retain_metadata = true,
    }).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn fatal(arg: []const u8, comptime typ: union(enum) {
    unknown: type,
    needs_arg: type,
    invalid: type,
}) noreturn {
    switch (typ) {
        .unknown => |T| {
            std.log.err("Unknown option '{s}'", .{arg});
            std.log.err("Choose from:", .{});

            for (std.meta.fieldNames(T)) |name| {
                std.log.err("\t{s}", .{name});
            }
        },
        .needs_arg => |T| {
            std.log.err("Option '{s}' requires an argument", .{arg});
            switch (@typeInfo(T)) {
                .@"enum" => {
                    std.log.err("Choose from:", .{});

                    for (std.meta.tags(T)) |tag| {
                        std.log.err("\t{s}", .{@tagName(tag)});
                    }
                },
                .@"union" => {
                    std.log.err("Choose from:", .{});

                    inline for (comptime std.meta.tags(T)) |tag| {
                        if (@FieldType(T, @tagName(tag)) != void) continue;
                        std.log.err("\t{s}", .{@tagName(tag)});
                    }
                },
                .int,
                .comptime_int,
                => {
                    std.log.err("Choose an integer", .{});
                },
                .float,
                .comptime_float,
                => {
                    std.log.err("Choose a float", .{});
                },
                else => {
                    // String
                    if (T == []const u8 or T == [:0]const u8) {
                        std.log.err("Please provide a string", .{});
                    } else {
                        @compileError("Unsupported type " ++ @typeName(T));
                    }
                },
            }
        },
        .invalid => |T| {
            std.log.err("Option '{s}' received an invalid argument", .{arg});
            switch (@typeInfo(T)) {
                .@"enum", .@"union" => {
                    std.log.err("Choose from:", .{});

                    for (std.meta.fieldNames(T)) |name| {
                        std.log.err("\t{s}", .{name});
                    }
                },

                .comptime_int, .int => {
                    std.log.err("Choose an integer", .{});
                },

                inline else => |t| @compileError("invalid type " ++ @tagName(t)),
            }
        },
    }
    std.process.exit(1);
}

// TODO: Ugly, create or find a library for this
pub fn parseArgs(alloc: Allocator, default: RunOpts) !RunOpts {
    const eql = std.mem.eql;
    const Opts = runner.Opts;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    var opts = default;

    while (args.next()) |arg| {
        if (eql(u8, arg, "--type") or eql(u8, arg, "-t")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = Opts.Type });
            opts.type = std.meta.stringToEnum(Opts.Type, val) orelse fatal(arg, .{ .invalid = Opts.Type });
        } else if (eql(u8, arg, "--filter") or eql(u8, arg, "-f")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = []const u8 });
            opts.filter = val;
        } else if (eql(u8, arg, "--tty")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = std.io.tty.Config });
            if (eql(u8, val, "no_color")) {
                opts.tty = .no_color;
            } else if (eql(u8, val, "escape_codes")) {
                opts.tty = .escape_codes;
            } else fatal(arg, .{ .invalid = std.io.tty.Config });
        } else if (eql(u8, arg, "--prefix") or eql(u8, arg, "-p")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = []const u8 });
            opts.prefix = val;
        } else if (eql(u8, arg, "--dry") or eql(u8, arg, "-d")) {
            opts.dry_run = true;
        } else if (eql(u8, arg, "--min_time") or eql(u8, arg, "-mt")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = []const u8 });
            opts.min_runtime_ns = std.fmt.parseInt(u64, val, 10) catch fatal(arg, .{ .invalid = u64 });
        } else fatal(arg, .{ .unknown = enum { type, filter, tty, prefix, dry, min_time } });
    }

    return opts;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const opts = try parseArgs(arena.allocator(), .{
        .type = .testing,
        .tty = std.io.tty.detectConfig(std.io.getStdOut()),
    });

    try runner.runAll(
        gpa.allocator(),
        test_functions,
        constructor_functions,
        opts,
    );
}

const std = @import("std");
const runner = @import("runner.zig");
const profiling = @import("profiling.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const TestFn = runner.TestFn;
const TestInformation = runner.TestInformation;
const ContructorInformation = runner.ContructorInformation;
const File = std.fs.File;
const Statistics = @import("Statistics.zig");
const RunOpts = runner.Opts;
