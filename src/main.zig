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

pub fn parseArgs(alloc: Allocator, default: Config) !Config {
    const eql = std.mem.eql;
    const Opts = runner.Config;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    var opts = default;

    var test_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer test_names.deinit(alloc);

    var constructor_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer constructor_names.deinit(alloc);

    while (args.next()) |arg| {
        if (eql(u8, arg, "--type") or eql(u8, arg, "-t")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = Opts.Type });
            opts.type = std.meta.stringToEnum(Opts.Type, val) orelse fatal(arg, .{ .invalid = Opts.Type });
        } else if (eql(u8, arg, "--test") or eql(u8, arg, "-tst")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = []const u8 });
            try test_names.append(alloc, val);
        } else if (eql(u8, arg, "--constr") or eql(u8, arg, "-c")) {
            const val = args.next() orelse fatal(arg, .{ .needs_arg = []const u8 });
            try constructor_names.append(alloc, val);
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
        } else if (eql(u8, arg, "--debug") or eql(u8, arg, "-d")) {
            opts.debug = true;
        } else fatal(arg, .{ .unknown = enum { type, filter, tty, prefix, dry, min_time } });
    }

    if (test_names.items.len > 0) {
        opts.test_whitelist = try test_names.toOwnedSlice(alloc);
    }

    if (constructor_names.items.len > 0) {
        opts.constr_whitelist = try constructor_names.toOwnedSlice(alloc);
    }

    return opts;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const base_alloc: Allocator = switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => gpa.allocator(),
        else => std.heap.smp_allocator,
    };

    var arena = std.heap.ArenaAllocator.init(base_alloc);
    defer arena.deinit();

    const opts = try parseArgs(arena.allocator(), .{
        .type = .testing,
        .tty = std.io.tty.detectConfig(std.io.getStdOut()),
    });

    // var record: recording.RecordingAllocator = .init(base_alloc);
    // defer record.deinit();

    // const rec_alloc = record.allocator();

    try runner.runAll(
        base_alloc,
        // rec_alloc,
        &tests.default,
        &constructors.default,
        opts,
    );

    // try record.finish("dump.rec");
}

const std = @import("std");
const runner = @import("runner");
const recording = @import("recording");

const tests = @import("tests");
const constructors = @import("constructors");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Config = runner.Config;
