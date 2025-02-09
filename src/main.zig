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

fn simpleGpa(opts: runner.TestOpts) !profiling.ProfilingAllocator.Res {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

fn otherGpa(opts: runner.TestOpts) !profiling.ProfilingAllocator.Res {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .retain_metadata = true,
    }).init;
    defer _ = gpa.deinit();

    return runner.run(gpa.allocator(), opts);
}

pub fn parse(default: anytype, alloc: Allocator) !@TypeOf(default) {
    const T = @TypeOf(default);
    comptime assert(@typeInfo(T) == .@"struct");

    var opts = default;

    const FieldEnum = std.meta.FieldEnum(T);

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    args: while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) fatal(arg, .{ .unknown = FieldEnum });
        const field = std.meta.stringToEnum(FieldEnum, arg[2..]) orelse fatal(arg, .{ .unknown = FieldEnum });

        inline for (comptime std.meta.tags(FieldEnum)) |tag| {
            if (field == tag) {
                const FieldType = @FieldType(T, @tagName(tag));
                switch (@typeInfo(FieldType)) {
                    .@"enum" => |_| {
                        const value = args.next() orelse fatal(arg, .{ .needs_arg = FieldType });

                        @field(opts, @tagName(tag)) = std.meta.stringToEnum(FieldType, value) orelse
                            fatal(arg, .{ .unknown = FieldType });
                    },
                    .pointer => |info| {
                        const value = args.next() orelse fatal(arg, .{ .needs_arg = FieldType });

                        switch (info.size) {
                            .slice => {
                                if (FieldType == []const u8 or FieldType == [:0]const u8) {
                                    @field(opts, @tagName(tag)) = value;
                                } else if (info.child == []const u8) {
                                    @compileError("No arrays of strings for now");
                                } else @compileError("field type " ++ @typeName(FieldType) ++ " not supported");
                            },
                            else => @compileError("field type " ++ @typeName(FieldType) ++ " not supported"),
                        }
                    },
                    .int,
                    .comptime_int,
                    => {
                        const value = args.next() orelse fatal(arg, .{ .needs_arg = FieldType });

                        // TODO: remove the try and get error handling
                        @field(opts, @tagName(tag)) = try std.fmt.parseInt(FieldType, value, 10);
                    },

                    .float,
                    .comptime_float,
                    => {
                        const value = args.next() orelse fatal(arg, .{ .needs_arg = FieldType });

                        // TODO: remove the try and get error handling
                        @field(opts, @tagName(tag)) = try std.fmt.parseFloat(FieldType, value);
                    },

                    .@"union" => |_| {
                        const value = args.next() orelse fatal(arg, .{ .needs_arg = FieldType });

                        inline for (comptime std.meta.tags(FieldType)) |t| {
                            if (std.mem.eql(u8, value, @tagName(t))) {
                                if (std.meta.TagPayload(FieldType, t) != void)
                                    @panic("Only void payloads supported for now");

                                @field(opts, @tagName(tag)) = @field(FieldType, @tagName(t));
                                continue :args;
                            }
                        }

                        fatal(value, .{ .unknown = FieldType });
                    },

                    .bool => |_| {
                        @field(opts, @tagName(tag)) = true;
                    },

                    else => @compileError("field type " ++ @typeName(FieldType) ++ " not supported"),
                }

                continue :args;
            }
        }

        unreachable;
    }

    return opts;
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
            comptime assert(@typeInfo(T) == .@"enum");

            std.log.err("Option '{s}' received an invalid argument", .{arg});
            std.log.err("Choose from:", .{});

            for (std.meta.fieldNames(T)) |name| {
                std.log.err("\t{s}", .{name});
            }
        },
    }
    std.process.exit(1);
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const opts = try parse(
        runner.RunOpts{
            .type = .testing,
            .tty = std.io.tty.detectConfig(std.io.getStdOut()),
        },
        arena.allocator(),
    );

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
