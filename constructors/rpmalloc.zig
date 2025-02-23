pub fn init() Allocator {
    _ = rpmalloc.rpmalloc_initialize();

    return .{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

pub fn deinit() void {
    rpmalloc.rpmalloc_finalize();
}

const vtable: Allocator.VTable = .{
    .alloc = &alloc,
    .resize = &resize,
    .remap = &remap,
    .free = &free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    if (rpmalloc.rpaligned_alloc(alignment.toByteUnits(), len)) |slice| {
        return @alignCast(@ptrCast(slice));
    }
    return null;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = ret_addr;

    if (rpmalloc.rpaligned_realloc(memory.ptr, alignment.toByteUnits(), new_len, memory.len, rpmalloc.RPMALLOC_GROW_OR_FAIL)) |_| {
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    if (rpmalloc.rpaligned_realloc(memory.ptr, alignment.toByteUnits(), new_len, memory.len, 0)) |slice| {
        return @alignCast(@ptrCast(slice));
    }
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    rpmalloc.rpfree(memory.ptr);
}

const rpmalloc = @import("rpmalloc").rpmalloc;
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
