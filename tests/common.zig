/// Minially touch an allocation, to ensure it actually exists, but to influence
/// time as little as possible
pub inline fn touchAllocation(rand: Random, allocation: anytype) void {
    const info = @typeInfo(@TypeOf(allocation)).pointer;

    if (@typeInfo(info.child) != .int) {
        switch (info.size) {
            .one => allocation.* = undefined,
            .slice => {
                allocation[0] = undefined;
                allocation[allocation.len - 1] = undefined;
            },
            else => comptime unreachable,
        }
        return;
    }

    switch (info.size) {
        .one => allocation.* = rand.int(info.child),
        .slice => {
            allocation[0] = rand.int(info.child);
            allocation[allocation.len - 1] = rand.int(info.child);
        },
        else => comptime unreachable,
    }
}

pub inline fn allocRange(comptime T: type, rand: Random, alloc: Allocator, min: usize, max: usize) ![]T {
    return alloc.alloc(T, rand.intRangeAtMost(usize, min, max));
}

pub inline fn allocAlignedRange(comptime T: type, rand: Random, alloc: Allocator, comptime alignment: Alignment, min: usize, max: usize) ![]align(alignment.toByteUnits()) T {
    return alloc.alignedAlloc(T, alignment.toByteUnits(), rand.intRangeAtMost(usize, min, max));
}

const std = @import("std");

const Random = std.Random;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
