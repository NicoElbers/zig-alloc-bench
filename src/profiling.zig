/// A allocator that records data about all allocations, resizes and frees passing
/// through it. It provides methods to dump all it's metadata into a given file.
///
/// It has a significant amount of overhead in terms of memory usage and time,
/// but does not touch the allocator under test. Instead it has an additional
/// allocator used for it's own allocations
pub const ProfilingAllocator = struct {
    allocator_under_test: Allocator,
    arena: ArenaAllocator,
    timer: Timer,
    allocation_list: ArrayList(Allocation),
    error_list: ArrayList(Error),

    const Self = @This();

    pub const Res = extern struct {
        allocations: usize,
    };

    pub const Error = struct {
        pub const Type = enum {
            double_free,
            double_resize,
            double_allocation,

            resize_after_free,
            free_without_alloc,
            resize_without_alloc,
        };

        trace: ?std.builtin.StackTrace,
        err_type: Type,
    };

    pub const Allocation = struct {
        addr: usize,
        alloced: TimeTrace,
        length: usize,
        freed: ?TimeTrace = null,
        resize_time_list: ArrayList(TimeTrace) = .empty,

        pub const TimeTrace = struct {
            time_ns: u64,
            trace: ?std.builtin.StackTrace,
        };

        pub fn reuseAddr(self: *const Allocation, ret_addr: usize, addr: usize, profiling_allocator: *ProfilingAllocator) void {
            assert(self.addr == addr);

            // If we freed this allocation, we are allowed to reuse it's address
            // in future allocations
            if (self.freed == null) {
                return profiling_allocator.addError(ret_addr, .double_allocation);
            }
        }

        pub fn free(self: *Allocation, ret_addr: usize, free_time: u64, profiling_allocator: *ProfilingAllocator) void {
            if (self.freed != null) {
                return profiling_allocator.addError(ret_addr, .double_free);
            }

            const arena = profiling_allocator.arena.allocator();

            self.freed = .{
                .time_ns = free_time,
                .trace = captureStackTrace(arena, ret_addr),
            };
        }

        pub fn resize(self: *Allocation, ret_addr: usize, resize_time: u64, profiling_allocator: *ProfilingAllocator) void {
            if (self.freed != null) {
                return profiling_allocator.addError(ret_addr, .resize_after_free);
            }

            const arena = profiling_allocator.arena.allocator();

            self.resize_time_list.append(
                arena,
                .{
                    .time_ns = resize_time,
                    .trace = captureStackTrace(arena, ret_addr),
                },
            ) catch {};
        }
    };

    pub fn init(allocator_under_test: Allocator, backing_allocator: Allocator) Self {
        return .{
            .allocator_under_test = allocator_under_test,
            .arena = .init(backing_allocator),
            .timer = std.time.Timer.start() catch @panic("Must suppport timer"),
            .allocation_list = .empty,
            .error_list = .empty,
        };
    }

    pub fn allocator(self: *Self) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn getStats(self: *Self) !Statistics.Profiling {
        defer {
            self.arena.deinit();
            self.* = undefined;
        }
        return .{
            .allocations = self.allocation_list.items.len,
        };
    }

    /// Dumps all errors into the provided file.
    ///
    /// Returns whether there were any errors
    pub fn dumpErrors(self: *const Self, file: File) bool {
        const writer = file.writer();

        const debug_info = std.debug.getSelfDebugInfo() catch |e| blk: {
            writer.print("Getting debug info failed: {s}\n", .{@errorName(e)}) catch {};

            break :blk null;
        };

        var any_errors = false;
        for (self.error_list.items) |err| {
            any_errors = true;

            writer.print("\n------- Error : {s} ------\n\n", .{@tagName(err.err_type)}) catch {};

            if (debug_info) |di| {
                if (err.trace) |st| {
                    std.debug.writeStackTrace(st, writer, di, .escape_codes) catch |e| {
                        writer.print("Dumping stacktrace failed: {s}\n", .{@errorName(e)}) catch {};
                    };
                } else {
                    writer.print("StackTrace not found\n", .{}) catch {};
                }
            }
        }

        for (self.allocation_list.items) |item| {
            if (item.freed == null) {
                any_errors = true;

                writer.print("\n------- Leak : 0x{x} ------\n\n", .{item.addr}) catch {};

                if (debug_info) |di| {
                    if (item.alloced.trace) |st| {
                        std.debug.writeStackTrace(st, writer, di, .escape_codes) catch |e| {
                            writer.print("Dumping stacktrace failed: {s}\n", .{@errorName(e)}) catch {};
                        };
                    } else {
                        writer.print("StackTrace not found\n", .{}) catch {};
                    }
                }
            }
        }

        return any_errors;
    }

    pub fn dumpStats(self: *const Self, file: File) void {
        const AvgTime = struct {
            total: u64 = 0,
            count: usize = 0,

            pub fn avg_time_ns(s: @This()) u64 {
                if (s.count == 0) return 0;

                return s.total / s.count;
            }
        };

        var alloced: AvgTime = .{};
        var freed: AvgTime = .{};
        var resized: AvgTime = .{};
        for (self.allocation_list.items) |item| {
            alloced.total += item.alloced.time_ns;
            alloced.count += 1;

            freed.total += item.freed.?.time_ns;
            freed.count += 1;

            for (item.resize_time_list.items) |resize_item| {
                resized.total += resize_item.time_ns;
                resized.count += 1;
            }
        }

        const writer = file.writer();

        writer.print(
            \\ Stats:
            \\   allocation ({d:0>3}): {d} ns 
            \\   frees      ({d:0>3}): {d} ns 
            \\   resizes    ({d:0>3}): {d} ns 
            \\
        , .{
            // zig fmt: off
            alloced.count, alloced.avg_time_ns(),
            freed.count, freed.avg_time_ns(),
            resized.count, resized.avg_time_ns(),
        }) catch {};
        // When putting it inside the struct it isn't recognized :')
        // zig fmt: on
    }

    fn lastAddrReference(self: Self, addr: usize) ?*Allocation {
        // Iterate backwards
        for (0..self.allocation_list.items.len) |i| {
            const idx = self.allocation_list.items.len - i - 1;

            const item = &self.allocation_list.items[idx];
            if (item.addr == addr) return item;
        }
        return null;
    }

    fn captureStackTrace(backing_alloc: Allocator, ret_addr: usize) ?std.builtin.StackTrace {
        const addrs = backing_alloc.alloc(usize, 32) catch return null;
        var st: std.builtin.StackTrace = .{
            .index = 0,
            .instruction_addresses = addrs,
        };

        std.debug.captureStackTrace(ret_addr, &st);

        return st;
    }

    fn addError(self: *Self, ret_addr: usize, error_type: Error.Type) void {
        const arena = self.arena.allocator();

        self.error_list.append(self.arena.allocator(), .{
            .trace = captureStackTrace(arena, ret_addr),
            .err_type = error_type,
        }) catch {};
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        const maybe_ptr = self.allocator_under_test.rawAlloc(len, alignment, ret_addr);
        const time = self.timer.read();

        if (maybe_ptr) |ptr| {
            const addr = @intFromPtr(ptr);
            if (self.lastAddrReference(addr)) |ref| {
                ref.reuseAddr(ret_addr, addr, self);
            }

            const arena = self.arena.allocator();

            self.allocation_list.append(self.arena.allocator(), .{
                .addr = addr,
                .alloced = .{
                    .time_ns = time,
                    .trace = captureStackTrace(arena, ret_addr),
                },
                .length = len,
            }) catch {};
        }

        return maybe_ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        const did_resize = self.allocator_under_test.rawResize(buf, alignment, new_len, ret_addr);
        const time = self.timer.read();

        if (did_resize) {
            if (self.lastAddrReference(@intFromPtr(buf.ptr))) |ref| {
                ref.resize(ret_addr, time, self);
            } else {
                self.addError(@returnAddress(), .resize_without_alloc);
            }

            return did_resize;
        }

        return did_resize;
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        const ret = self.allocator_under_test.rawRemap(mem, alignment, new_len, ret_addr);
        const time = self.timer.read();

        if (ret) |r| {
            if (self.lastAddrReference(@intFromPtr(mem.ptr))) |ref| {
                const arena = self.arena.allocator();

                ref.free(ret_addr, time, self);

                self.allocation_list.append(self.arena.allocator(), .{
                    .addr = @intFromPtr(r),
                    .alloced = .{
                        .time_ns = time,
                        .trace = captureStackTrace(arena, ret_addr),
                    },
                    .length = new_len,
                }) catch {};
            }
        }

        return ret;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        self.allocator_under_test.rawFree(buf, alignment, ret_addr);
        const time = self.timer.read();

        if (self.lastAddrReference(@intFromPtr(buf.ptr))) |ref| {
            ref.free(ret_addr, time, self);
        } else {
            self.addError(ret_addr, .free_without_alloc);
        }
    }
};

const std = @import("std");

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;
const HashMap = std.AutoHashMapUnmanaged;
const ArrayList = std.ArrayListUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;
const Statistics = @import("Statistics.zig");
const Alignment = std.mem.Alignment;

const assert = std.debug.assert;
