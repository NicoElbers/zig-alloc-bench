const mimalloc = @cImport({
    @cInclude("mimalloc.h");
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

    if (mimalloc.mi_aligned_alloc(alignment.toByteUnits(), len)) |ptr| {
        return @alignCast(@ptrCast(ptr));
    }
    return null;
}
fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;

    return mimalloc.mi_expand(memory.ptr, new_len) != null;
}
fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;

    if (mimalloc.mi_realloc_aligned(memory.ptr, new_len, alignment.toByteUnits())) |ptr| {
        return @alignCast(@ptrCast(ptr));
    }
    return null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = ret_addr;

    mimalloc.mi_free_aligned(memory.ptr, alignment.toByteUnits());
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
