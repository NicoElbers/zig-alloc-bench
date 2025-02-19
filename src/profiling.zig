pub const Profiling = struct {
    allocations: FallableTally = .init,
    resizes: FallableTally = .init,
    remaps: FallableTally = .init,
    frees: LazyTally = .init,

    pub fn zonable(self: *const Profiling) Zonable {
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

    timer: Timer,
    profiling: *Profiling,

    const Self = @This();

    pub fn init(allocator_under_test: Allocator, profiling: *Profiling) Self {
        return .{
            .allocator_under_test = allocator_under_test,
            .timer = std.time.Timer.start() catch @panic("Must suppport timer"),
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

        self.timer.reset();
        const maybe_ptr = self.allocator_under_test.rawAlloc(len, alignment, ret_addr);
        const time = self.timer.read();

        if (maybe_ptr) |_| {
            self.profiling.allocations.addSuccess(@floatFromInt(time));
        } else {
            self.profiling.allocations.addFailure(@floatFromInt(time));
        }

        return maybe_ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        const did_resize = self.allocator_under_test.rawResize(buf, alignment, new_len, ret_addr);
        const time = self.timer.read();

        if (did_resize) {
            self.profiling.resizes.addSuccess(@floatFromInt(time));
        } else {
            self.profiling.resizes.addFailure(@floatFromInt(time));
        }

        return did_resize;
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        const maybe_ptr = self.allocator_under_test.rawRemap(mem, alignment, new_len, ret_addr);
        const time = self.timer.read();

        if (maybe_ptr) |_| {
            self.profiling.remaps.addSuccess(@floatFromInt(time));
        } else {
            self.profiling.remaps.addFailure(@floatFromInt(time));
        }

        return maybe_ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ProfilingAllocator = @ptrCast(@alignCast(ctx));

        self.timer.reset();
        self.allocator_under_test.rawFree(buf, alignment, ret_addr);
        const time = self.timer.read();

        self.profiling.frees.add(@floatFromInt(time));
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

const assert = std.debug.assert;
