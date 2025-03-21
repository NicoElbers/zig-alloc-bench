//! NOTE: This is a copy from https://gist.github.com/silversquirl/c1e4840048fdf48e669b6eac76d80634
//! with minimal changes
//!
//! A bug was found in multithreaded leak reporting. Not fixing, simply disabling

// BSD Zero Clause License
//
// Copyright (C) 2023 by silversquirl
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
// REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
// INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
// LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
// OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
// PERFORMANCE OF THIS SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    /// Whether to synchronize usage of this allocator.
    /// For actual thread safety, the backing allocator must also be thread safe.
    thread_safe: bool = !builtin.single_threaded,

    /// Whether to warn about leaked memory on deinit.
    /// This reporting is extremely limited; for proper leak checking use GeneralPurposeAllocator.
    report_leaks: bool = true,
};

pub fn BinnedAllocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        bins: Bins = .{},
        large_count: if (config.report_leaks) usize else u0 = 0,

        const Bins = struct {
            @"16": Bin(16, 8) = .init,
            @"64": Bin(64, 4) = .init,
            @"256": Bin(256, 2) = .init,
            @"1024": Bin(1024, 0) = .init,
            @"4096": Bin(4096, 0) = .init,
        };
        comptime {
            var prev: usize = 0;

            for (std.meta.fieldNames(Bins)) |bin_name| {
                const bin: @FieldType(Bins, bin_name) = .init;
                std.debug.assert(bin.size > prev);
                prev = bin.size;
            }
        }

        const Self = @This();

        pub fn deinit(self: *Self) void {
            const log = std.log.scoped(.binned_allocator);

            // FIXME: https://github.com/ziglang/zig/issues/14705
            inline for (comptime std.meta.fieldNames(Bins)) |bin_name| {
                const bin = &@field(self.bins, bin_name);
                if (config.report_leaks) {
                    const leaks = bin.list.count() - bin.freeCount();
                    if (leaks > 0) {
                        log.warn("{} leaked blocks in {}-byte bin", .{ leaks, bin.size });
                    }
                }
                bin.deinit(self.backing_allocator);
            }

            if (config.report_leaks) {
                if (self.large_count > 0) {
                    log.warn("{} large blocks leaked. Large leaks cannot be cleaned up!", .{self.large_count});
                }
            }
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
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

        // fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const align_ = alignment.toByteUnits();
            const size = @max(len, align_);
            // FIXME: https://github.com/ziglang/zig/issues/14705
            inline for (comptime std.meta.fieldNames(Bins)) |bin_name| {
                const bin = &@field(self.bins, bin_name);
                if (size <= bin.size) {
                    return bin.alloc(self.backing_allocator);
                }
            }

            if (self.backing_allocator.rawAlloc(len, alignment, ret_addr)) |ptr| {
                if (config.report_leaks) self.large_count += 1;
                return ptr;
            } else {
                return null;
            }
        }

        fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const align_ = alignment.toByteUnits();
            comptime var prev_size: usize = 0;
            // FIXME: https://github.com/ziglang/zig/issues/14705
            inline for (comptime std.meta.fieldNames(Bins)) |bin_name| {
                const bin = &@field(self.bins, bin_name);
                if (buf.len <= bin.size and align_ <= bin.size) {
                    // Check it still fits
                    return new_len > prev_size and new_len <= bin.size;
                }
                prev_size = bin.size;
            }

            // Assuming it's a large alloc
            if (new_len <= prev_size) return false; // New size fits into a bin
            return self.backing_allocator.rawResize(buf, alignment, new_len, ret_addr);
        }

        pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            if (resize(ctx, memory, alignment, new_len, ret_addr)) return memory.ptr;
            return null;
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const align_ = alignment.toByteUnits();
            // FIXME: https://github.com/ziglang/zig/issues/14705
            inline for (comptime std.meta.fieldNames(Bins)) |bin_name| {
                const bin = &@field(self.bins, bin_name);
                if (buf.len <= bin.size and align_ <= bin.size) {
                    bin.free(buf.ptr);
                    return;
                }
            }

            // Assuming it's a large alloc
            self.backing_allocator.rawFree(buf, alignment, ret_addr);
            if (config.report_leaks) self.large_count -= 1;
        }

        const Mutex = if (config.thread_safe)
            std.Thread.Mutex
        else
            struct {
                fn lock(_: @This()) void {}
                fn unlock(_: @This()) void {}
            };

        fn Bin(comptime slot_size: usize, comptime init_count: usize) type {
            return struct {
                mutex: Mutex = .{},
                list: std.SegmentedList(Slot(slot_size), init_count) = .{},
                free_head: ?*Slot(slot_size) = null,
                comptime size: usize = slot_size,

                pub const init: @This() = .{};

                fn deinit(self: *@This(), al: std.mem.Allocator) void {
                    self.list.deinit(al);
                }

                fn alloc(self: *@This(), al: std.mem.Allocator) ?[*]u8 {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    const slot = if (self.free_head) |s| blk: {
                        self.free_head = s.next;
                        break :blk s;
                    } else self.list.addOne(al) catch return null;
                    slot.* = .{ .buf = undefined };
                    return &slot.buf;
                }

                fn free(self: *@This(), ptr: [*]u8) void {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    const slot: *Slot(slot_size) = @ptrCast(@alignCast(ptr));
                    slot.* = .{ .next = self.free_head };
                    self.free_head = slot;
                }

                // Only public in case someone wants to dump out internal allocator debug info
                pub fn freeCount(self: *@This()) usize {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    var slot_opt = self.free_head;
                    var count: usize = 0;
                    while (slot_opt) |slot| : (slot_opt = slot.next) {
                        count += 1;
                    }
                    return count;
                }
            };
        }
        fn Slot(comptime size: usize) type {
            return extern union {
                buf: [size]u8 align(size), // Allocated
                next: ?*@This(), // Free

                comptime {
                    if (@sizeOf(@This()) != size or @alignOf(@This()) != size) {
                        @compileError("Slot size too small!");
                    }
                }
            };
        }
    };
}

test "small allocations - free in same order" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    for (list.items) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - free in reverse order" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var list = std.ArrayList(*u64).init(std.testing.allocator);
    defer list.deinit();

    var i: usize = 0;
    while (i < 513) : (i += 1) {
        const ptr = try allocator.create(u64);
        try list.append(ptr);
    }

    while (list.popOrNull()) |ptr| {
        allocator.destroy(ptr);
    }
}

test "small allocations - alloc free alloc" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    const a = try allocator.create(u64);
    allocator.destroy(a);
    const b = try allocator.create(u64);
    allocator.destroy(b);
}

test "large allocations" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    const ptr1 = try allocator.alloc(u64, 42768);
    const ptr2 = try allocator.alloc(u64, 52768);
    allocator.free(ptr1);
    const ptr3 = try allocator.alloc(u64, 62768);
    allocator.free(ptr3);
    allocator.free(ptr2);
}

test "very large allocation" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
}

test "realloc" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice = try allocator.alignedAlloc(u8, @alignOf(u32), 1);
    defer allocator.free(slice);
    slice[0] = 0x12;

    // This reallocation should keep its pointer address.
    const old_slice = slice;
    slice = try allocator.realloc(slice, 2);
    try std.testing.expect(old_slice.ptr == slice.ptr);
    try std.testing.expect(slice[0] == 0x12);
    slice[1] = 0x34;

    // This requires upgrading to a larger bin size
    slice = try allocator.realloc(slice, 17);
    try std.testing.expect(old_slice.ptr != slice.ptr);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[1] == 0x34);
}

test "shrink" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice = try allocator.alloc(u8, 20);
    defer allocator.free(slice);

    @memset(slice, 0x11);

    try std.testing.expect(allocator.resize(slice, 17));
    slice = slice[0..17];

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }

    try std.testing.expect(!allocator.resize(slice, 16));

    for (slice) |b| {
        try std.testing.expect(b == 0x11);
    }
}

test "large object - grow" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice1 = try allocator.alloc(u8, 8192 - 20);
    defer allocator.free(slice1);

    const old = slice1;
    slice1 = try allocator.realloc(slice1, 8192 - 10);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, 8192);
    try std.testing.expect(slice1.ptr == old.ptr);

    slice1 = try allocator.realloc(slice1, 8192 + 1);
}

test "realloc small object to large object" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice = try allocator.alloc(u8, 70);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    // This requires upgrading to a large object
    const large_object_size = 8192 + 50;
    slice = try allocator.realloc(slice, large_object_size);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[60] = 0x34;

    if (!allocator.resize(slice, 8192 + 1)) return;
    slice = slice.ptr[0 .. 8192 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    try std.testing.expect(allocator.resize(slice, 8192 + 1));
    slice = slice[0 .. 8192 + 1];
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);

    slice = try allocator.realloc(slice, 8192);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "shrink large object to large object with larger alignment" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    const alloc_size = 8192 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => 65536, // Windows aligns to 64K.
        else => 8192,
    };
    // This loop allocates until we find a page that is not aligned to the big
    // alignment. Then we shrink the allocation after the loop, but increase the
    // alignment to the higher one, that we know will force it to realloc.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (std.mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    slice = try allocator.reallocAdvanced(slice, big_alignment, alloc_size / 2);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[60] == 0x34);
}

test "realloc large object to small object" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.realloc(slice, 19);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "non-page-allocator backing allocator" {
    var binned = BinnedAllocator(.{}){ .backing_allocator = std.testing.allocator };
    defer binned.deinit();
    const allocator = binned.allocator();

    const ptr = try allocator.create(i32);
    defer allocator.destroy(ptr);
}

test "realloc large object to larger alignment" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    var debug_buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&debug_buffer);
    const debug_allocator = fba.allocator();

    var slice = try allocator.alignedAlloc(u8, 16, 8192 + 50);
    defer allocator.free(slice);

    const big_alignment: usize = switch (builtin.os.tag) {
        .windows => 65536, // Windows aligns to 64K.
        else => 8192,
    };
    // This loop allocates until we find a page that is not aligned to the big alignment.
    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    while (std.mem.isAligned(@intFromPtr(slice.ptr), big_alignment)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, 8192 + 50);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[16] = 0x34;

    slice = try allocator.reallocAdvanced(slice, 32, 8192 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, 32, 8192 + 25);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);

    slice = try allocator.reallocAdvanced(slice, big_alignment, 8192 + 100);
    try std.testing.expect(slice[0] == 0x12);
    try std.testing.expect(slice[16] == 0x34);
}

test "large object does not shrink to small" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    const slice = try allocator.alloc(u8, 8192 + 50);
    defer allocator.free(slice);

    try std.testing.expect(!allocator.resize(slice, 4));
}

test "objects of size 1024 and 2048" {
    var binned = BinnedAllocator(.{}){};
    defer binned.deinit();
    const allocator = binned.allocator();

    const slice = try allocator.alloc(u8, 1025);
    const slice2 = try allocator.alloc(u8, 3000);

    allocator.free(slice);
    allocator.free(slice2);
}
