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
        tests.default,
        allocators.default,
        opts,
    );
}

const std = @import("std");
const runner = @import("runner");

const tests = @import("tests");
const allocators = @import("allocators");

const assert = std.debug.assert;

const Profiling = runner.Profiling;
const Allocator = std.mem.Allocator;
const TestFn = runner.TestFn;
const TestInformation = runner.TestInformation;
const ContructorInformation = runner.ContructorInformation;
const File = std.fs.File;
const RunOpts = runner.Opts;
