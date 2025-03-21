pub const Profiling = struct {
    allocations: FallableTally = .init,
    resizes: FallableTally = .init,
    remaps: FallableTally = .init,
    frees: LazyTally = .init,

    pub fn zonable(self: *Profiling) Zonable {
        const allocations = self.allocations.zonable();
        const resizes = self.resizes.zonable();
        const remaps = self.remaps.zonable();

        return .{
            .allocations = allocations.success,
            .resizes_success = resizes.success,
            .resizes_failure = resizes.failure,
            .remaps_success = remaps.success,
            .remaps_failure = remaps.failure,
            .frees = self.frees.zonable(),
        };
    }

    pub const Zonable = struct {
        allocations: ?Tally.Zonable,
        resizes_success: ?Tally.Zonable,
        resizes_failure: ?Tally.Zonable,
        remaps_success: ?Tally.Zonable,
        remaps_failure: ?Tally.Zonable,
        frees: ?Tally.Zonable,

        pub fn add(self: *Zonable, o: Zonable) void {
            inline for (comptime std.meta.fieldNames(Zonable)) |name| {
                if (@field(o, name)) |other_field| {
                    if (@field(self, name) == null) @field(self, name) = .init;

                    const self_field = &@field(self, name).?;

                    inline for (comptime std.meta.fieldNames(Tally.Zonable)) |inner_name| {
                        @field(self_field, inner_name) += @field(other_field, inner_name);
                    }
                }
            }
        }

        pub fn div(self: *Zonable, by: f64) void {
            inline for (comptime std.meta.fieldNames(Zonable)) |name| {
                if (@field(self, name)) |*field| {
                    inline for (comptime std.meta.fieldNames(Tally.Zonable)) |inner_name| {
                        @field(field, inner_name) /= by;
                    }
                }
            }
        }

        pub const init: Zonable = .{
            .allocations = null,
            .resizes_success = null,
            .resizes_failure = null,
            .remaps_success = null,
            .remaps_failure = null,
            .frees = null,
        };
    };

    pub const init: Profiling = .{};
};

/// A allocator that records data about all allocations, resizes and frees passing
/// through it. It provides methods to dump all it's metadata into a given file.
///
/// It has a significant amount of overhead in terms of memory usage and time,
/// but does not touch the allocator under test. Instead it has an additional
/// allocator used for it's own allocations
pub const ProfilingAllocator = struct {
    allocator_under_test: Allocator,
    profiling: *Profiling,
    lock: Mutex = .{},

    const Self = @This();

    pub fn init(allocator_under_test: Allocator, profiling: *Profiling) Self {
        return .{
            .allocator_under_test = allocator_under_test,
            .profiling = profiling,
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

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        var timer = Timer.start() catch unreachable;
        const maybe_ptr = self.allocator_under_test.rawAlloc(len, alignment, ret_addr);
        const time = timer.read();

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (maybe_ptr) |_| {
                self.profiling.allocations.addSuccess(@floatFromInt(time));
            } else {
                self.profiling.allocations.addFailure(@floatFromInt(time));
            }
        }

        return maybe_ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        var timer = Timer.start() catch unreachable;
        const did_resize = self.allocator_under_test.rawResize(buf, alignment, new_len, ret_addr);
        const time = timer.read();

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (did_resize) {
                self.profiling.resizes.addSuccess(@floatFromInt(time));
            } else {
                self.profiling.resizes.addFailure(@floatFromInt(time));
            }
        }

        return did_resize;
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        var timer = Timer.start() catch unreachable;
        const maybe_ptr = self.allocator_under_test.rawRemap(mem, alignment, new_len, ret_addr);
        const time = timer.read();

        {
            self.lock.lock();
            defer self.lock.unlock();

            if (maybe_ptr) |_| {
                self.profiling.remaps.addSuccess(@floatFromInt(time));
            } else {
                self.profiling.remaps.addFailure(@floatFromInt(time));
            }
        }

        return maybe_ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        var timer = Timer.start() catch unreachable;
        self.allocator_under_test.rawFree(buf, alignment, ret_addr);
        const time = timer.read();

        {
            self.lock.lock();
            defer self.lock.unlock();

            self.profiling.frees.add(@floatFromInt(time));
        }
    }
};

const std = @import("std");
const statistics = @import("statistics.zig");

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;
const Alignment = std.mem.Alignment;
const Tally = statistics.Tally;
const LazyTally = statistics.LazyTally;
const FallableTally = statistics.FallableTally;
const Mutex = std.Thread.Mutex;

const assert = std.debug.assert;
