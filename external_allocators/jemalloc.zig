const jemalloc = @cImport({
    @cInclude("jemalloc.h");
});

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

pub const vtable: Allocator.VTable = .{
    .alloc = &alloc,
    .remap = &remap,
    .resize = &resize,
    .free = &free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    if (jemalloc.je_mallocx(len, jemalloc.MALLOCX_ALIGN(alignment.toByteUnits()))) |ptr| {
        return @alignCast(@ptrCast(ptr));
    }
    return null;
}
fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    const real_size = jemalloc.je_xallocx(memory.ptr, new_len, 0, 0);
    return real_size >= new_len;
}
fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    if (jemalloc.rallocx(memory.ptr, new_len, jemalloc.MALLOCX_ALIGN(alignment.toByteUnits()))) |ptr| {
        return @alignCast(@ptrCast(ptr));
    }
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    jemalloc.je_free(memory.ptr);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
