backing_alloc: Allocator,
file: File,
mutex: Mutex,

pub const vtable: Allocator.VTable = .{
    .alloc = &alloc,
    .remap = &remap,
    .resize = &resize,
    .free = &free,
};

const RecordingAllocator = @This();

pub fn init(backing_allocator: Allocator, output_name: [:0]const u8) !RecordingAllocator {
    const file = try std.fs.cwd().createFileZ(output_name, .{});

    return .{
        .backing_alloc = backing_allocator,
        .file = file,
        .mutex = .{},
    };
}

pub fn deinit(self: *RecordingAllocator) void {
    self.file.close();

    self.* = undefined;
}

pub fn allocator(self: *RecordingAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *RecordingAllocator = @alignCast(@ptrCast(ctx));

    const ret = self.backing_alloc.rawAlloc(len, alignment, ret_addr);

    if (ret) |r| {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.file.writer().print(
            "a {d} {d} {d}\n",
            .{ @intFromPtr(r), len, alignment.toByteUnits() },
        ) catch @panic("Write error");
    }

    return ret;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *RecordingAllocator = @alignCast(@ptrCast(ctx));

    const ret = self.backing_alloc.rawResize(memory, alignment, new_len, ret_addr);

    if (ret) {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.file.writer().print(
            "s {d} {d} {d}\n",
            .{ @intFromPtr(memory.ptr), new_len, alignment.toByteUnits() },
        ) catch @panic("Write error");
    }

    return ret;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *RecordingAllocator = @alignCast(@ptrCast(ctx));

    const ret = self.backing_alloc.rawRemap(memory, alignment, new_len, ret_addr);

    if (ret) |r| {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.file.writer().print(
            "m {d} {d} {d} {d}\n",
            .{
                @intFromPtr(memory.ptr),
                new_len,
                alignment.toByteUnits(),
                @intFromPtr(r),
            },
        ) catch @panic("Write error");
    }

    return ret;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *RecordingAllocator = @alignCast(@ptrCast(ctx));

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.file.writer().print(
            "f {d} {d}\n",
            .{
                @intFromPtr(memory.ptr),
                alignment.toByteUnits(),
            },
        ) catch @panic("Write error");
    }

    return self.backing_alloc.rawFree(memory, alignment, ret_addr);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const File = std.fs.File;
const Mutex = std.Thread.Mutex;
