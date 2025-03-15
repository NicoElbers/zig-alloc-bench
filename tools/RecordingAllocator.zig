//! This is an allocator that records sequences of allocations and which thread
//! they happened on. This means that we can perfectly play back the allocation
//! characteristics without having to put the entire project in tree.
//!
//! This approach is limited in 2 primary ways. We do not record how the data is
//! used, nor do we keep track of attempted, but failed, remaps and resizes. This
//! also raised the point that when playing back, there is no way to force a
//! resize or a remap, thus these will need naive backups when they fail to keep
//! the test equal.
//!
//! Dumps created by this allocator are in a custom binary format. This is done
//! due to the fact most applications perform a lot of updates on allocations
//! so to keep under GitHubs 100Mb limit, we have to optimize for space. The
//! alternative for this would be compression, but decompression is a very slow
//! to do, especially in a benchmark. Therefore I decided to go for this.
//!
//! The binary format consists of a header and a body. Every integer and struct
//! in the format is written in little endian.
//!
//! The header consists of, in order:
//! - 2 magic bytes `&.{ 'r', 0xec }`
//! - 1 version byte, this is version 1 (`0b1`)
//! - A `u32` consisting of the total amount of updates
//! - A `u32` consisting of the total amount of sequences
//! - N `u32`s consisting of the size per sequence, where N is the total amount
//!   of sequences
//!
//! The body consists of, in order:
//! - N times the `Update.Store` struct, as found in `recording_types.zig`, where
//!   N is the total amount of updates
//! - N sequences of size Mi `Index`s, as found in `recording_types.zig`, where
//!   N is the total amount of sequences and Mi is the ith element in the list
//!   of sequence sizes defined in the header.

backing: Allocator,
arena: ArenaAllocator,
allocations: AutoHashMapUnmanaged(Pointer, ArrayListUnmanaged(Index)) = .empty,
sequences: ArrayListUnmanaged([]const Index) = .empty,
updates: ArrayListUnmanaged(Update) = .empty,
mutex: Mutex = .{},

const Tid = struct {
    threadlocal var tid: ?Id = null;
    pub fn get() Id {
        if (Tid.tid) |id| {
            @branchHint(.likely);
            return id;
        }

        tid = Thread.getCurrentId();
        return tid.?;
    }
};

pub fn init(backing: Allocator) @This() {
    return .{
        .backing = backing,
        .arena = .init(backing),
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub fn finish(self: *@This(), dump_name: [:0]const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.allocations.size > 0) {
        std.log.err("Leaked {d} allocations", .{self.allocations.size});
        return error.Leaked;
    }

    const file = try std.fs.cwd().createFileZ(dump_name, .{});
    defer file.close();

    const writer = file.writer();

    // == Header ==

    // Magic
    try writer.writeAll(recording.magic);

    // Version
    try writer.writeInt(u8, 1, .little);

    // Amount of updates
    try writer.writeInt(u32, @intCast(self.updates.items.len), .little);

    // Amount of sequences
    try writer.writeInt(u32, @intCast(self.sequences.items.len), .little);

    // Per sequence, the sequence length
    for (self.sequences.items) |s| {
        try writer.writeInt(u32, @intCast(s.len), .little);
    }

    // == Body ==

    // Actual updates
    for (self.updates.items) |u| {
        try writer.writeStructEndian(Update.Store.fromUpdate(u), .little);
    }

    // Actual Sequences
    for (self.sequences.items) |s| {
        for (s) |idx| {
            try writer.writeInt(u32, @intFromEnum(idx), .little);
        }
    }
}

const vtable: Allocator.VTable = .{
    .alloc = &alloc,
    .resize = &resize,
    .remap = &remap,
    .free = &free,
};

pub fn allocator(self: *@This()) Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn addUpdate(self: *@This(), sequence: *ArrayListUnmanaged(Index), update: Update) !void {
    const tid = Tid.get();

    if (sequence.getLastOrNull()) |last_id| {
        const last = self.updates.items[last_id.to()];

        if (last.tid != tid) {
            try sequence.append(self.arena.allocator(), .from(self.updates.items.len));
            try self.updates.append(self.arena.allocator(), .{
                .action = .transfer,
                .alignm = last.alignm,
                .size = last.size,
                .tid = tid,
            });
        }
    }

    try sequence.append(self.arena.allocator(), .from(self.updates.items.len));
    try self.updates.append(self.arena.allocator(), update);
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    const ret = self.backing.rawAlloc(len, alignment, ret_addr);

    if (ret) |r| {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.allocations.getOrPut(
            self.arena.allocator(),
            .from(r),
        ) catch @panic("Failed to record");

        if (gop.found_existing)
            std.debug.panic("Double allocation of pointer {*}", .{r})
        else
            gop.value_ptr.* = .empty;

        self.addUpdate(gop.value_ptr, .{
            .action = .alloc,
            .alignm = alignment,
            .tid = Tid.get(),
            .size = @intCast(len),
        }) catch @panic("Failed to record");
    }

    return ret;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    const ret = self.backing.rawResize(memory, alignment, new_len, ret_addr);

    if (ret) {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = self.allocations.getOrPut(
            self.arena.allocator(),
            .from(memory.ptr),
        ) catch @panic("Failed to record");

        if (!gop.found_existing)
            std.debug.panic("Invalid resize of {*}", .{memory.ptr});

        self.addUpdate(gop.value_ptr, .{
            .action = .resize,
            .alignm = alignment,
            .tid = Tid.get(),
            .size = @intCast(new_len),
        }) catch @panic("Failed to record");
    }

    return ret;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    const ret = self.backing.rawRemap(memory, alignment, new_len, ret_addr);

    if (ret) |r| {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old = self.allocations.fetchRemove(.from(memory.ptr)) orelse
            std.debug.panic("Invalid remap of {*}", .{memory.ptr});

        const new = self.allocations.getOrPut(
            self.arena.allocator(),
            .from(memory.ptr),
        ) catch @panic("Failed to record");

        if (new.found_existing)
            std.debug.panic("Double allocation of pointer {*}", .{r})
        else
            new.value_ptr.* = old.value;

        self.addUpdate(new.value_ptr, .{
            .action = .remap,
            .alignm = alignment,
            .tid = Tid.get(),
            .size = @intCast(new_len),
        }) catch @panic("Failed to record");
    }

    return ret;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *@This() = @ptrCast(@alignCast(ctx));

    self.backing.rawFree(memory, alignment, ret_addr);

    self.mutex.lock();
    defer self.mutex.unlock();

    const KV = AutoHashMapUnmanaged(Pointer, ArrayListUnmanaged(Index)).KV;
    var kv: KV = self.allocations.fetchRemove(.from(memory.ptr)) orelse
        std.debug.panic("Invalid free of {*}", .{memory.ptr});

    // Finish the allocation off with a free
    self.addUpdate(&kv.value, .{
        .action = .free,
        .alignm = alignment,
        .tid = Tid.get(),
        .size = @intCast(memory.len),
    }) catch @panic("Failed to record");

    const idxs: []const Index = kv.value.items;

    var begin: usize = 0;
    for (idxs, 0..) |idx, i| {
        const update = self.updates.items[idx.to()];

        if (update.action != .transfer)
            continue;

        // Ensure the transfer action is is this _and_ the next sequence
        // so that the waiting thread waits on the same semaphore
        self.sequences.append(self.arena.allocator(), idxs[begin .. i + 1]) catch
            @panic("Failed to record");
        begin = i;
    }

    self.sequences.append(self.arena.allocator(), idxs[begin..]) catch
        @panic("Failed to record");
}

comptime {
    _ = &finish;
    _ = &allocator;
}

const std = @import("std");
const recording = @import("recording.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Alignment = std.mem.Alignment;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Thread = std.Thread;
const Id = Thread.Id;
const File = std.fs.File;
const Mutex = Thread.Mutex;
const Semaphore = Thread.Semaphore;
const Update = recording.Update;
const Index = recording.Index;
const Pointer = recording.Pointer;
const Action = recording.Action;
