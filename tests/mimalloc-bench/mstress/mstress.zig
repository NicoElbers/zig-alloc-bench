//! ------------------------------------------------------------------------------
//! Copyright (c) 2018,2019 Microsoft Research, Daan Leijen
//! This is free software; you can redistribute it and/or modify it under the
//! terms of the MIT license.
//! -----------------------------------------------------------------------------
//!
//! This is a stress test for the allocator, using multiple threads and
//! transferring objects between threads. This is not a typical workload
//! but uses a random linear size distribution. *Do not use this test as a benchmark*!
//!
//! Ported to Zig and modified to the Zig Allocator interface

const allow_large_objects = true;
const use_one_size = 0;

const AtomicSlice = struct {
    slice: ?[]usize = null,
    mutex: Thread.Mutex = .{},

    pub fn lock(self: *AtomicSlice) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *AtomicSlice) void {
        self.mutex.unlock();
    }
};

const Args = struct {
    rand: Random,
    transfer: []AtomicSlice,
    scale: usize,
};

fn allocSize(n: usize, rand: Random) usize {
    const chance = rand.float(f32);

    return if (chance < 0.0001)
        n * 10_000
    else if (chance < 0.001)
        n * 1_000
    else if (chance < 0.01)
        n * 100
    else
        n;
}

fn allocItems(alloc: Allocator, n: usize, rand: Random) ![]usize {
    const actual_n = allocSize(n, rand);
    const items = try alloc.alloc(usize, actual_n);

    const cookie = rand.int(usize);
    for (items, 0..) |*item, i| item.* = (actual_n - i) ^ cookie;

    return @ptrCast(items);
}

fn worker(alloc: Allocator, args: Args) !void {
    const rand = args.rand;

    // Have some threads do more work
    var allocs = 100 * args.scale * rand.intRangeAtMost(u8, 1, 8);
    var retain = allocs / 2;

    var data: ArrayListUnmanaged(?[]usize) = try .initCapacity(alloc, allocs);
    defer data.deinit(alloc);

    var retained: ArrayListUnmanaged([]usize) = try .initCapacity(alloc, retain);
    defer retained.deinit(alloc);

    while (allocs > 0 or retain > 0) {
        {
            const n: usize = @as(usize, 1) << rand.intRangeAtMost(u3, 0, 5);

            // 50/50 to add an item to the data or retained list, or fill up
            // the other one
            if (retain == 0 or
                (rand.boolean() and allocs > 0))
            {
                allocs -= 1;
                data.appendAssumeCapacity(try allocItems(alloc, n, rand));
            } else {
                retain -= 1;
                retained.appendAssumeCapacity(try allocItems(alloc, n, rand));
            }
        }

        // << Added

        // 80% to remap a previous allocation
        if (rand.float(f32) < 0.80 and data.items.len > 0) {
            const idx = rand.intRangeLessThan(usize, 0, data.items.len);

            if (data.items[idx]) |*item| {
                const n: usize = @as(usize, 1) << rand.intRangeAtMost(u3, 0, 5);
                const new_size = allocSize(n, rand);

                if (alloc.remap(item.*, new_size)) |ret| {
                    item.* = ret;
                }
            }
        }

        // 80% to resize a previous allocation
        if (rand.float(f32) < 0.80 and data.items.len > 0) {
            const idx = rand.intRangeLessThan(usize, 0, data.items.len);

            if (data.items[idx]) |*item| {
                const n: usize = @as(usize, 1) << rand.intRangeAtMost(u3, 0, 5);
                const new_size = allocSize(n, rand);

                if (alloc.resize(item.*, new_size)) {
                    item.len = new_size;
                }
            }
        }

        // >> Added

        // 66% to free a previous allocation
        if (rand.float(f32) < 0.66 and data.items.len > 0) {
            const idx = rand.intRangeLessThan(usize, 0, data.items.len);

            if (data.items[idx]) |item| {
                alloc.free(item);
                data.items[idx] = null;
            }
        }

        // 25% to exchange an item with another thread
        if (rand.float(f32) < 0.25 and data.items.len > 0) {
            const idx = rand.intRangeLessThan(usize, 0, @min(data.items.len, args.transfer.len));

            const transfer = &args.transfer[idx];
            {
                transfer.lock();
                defer transfer.unlock();

                swap(?[]usize, &transfer.slice, &data.items[idx]);
            }
        }
    }

    // Free remaining items
    for (data.items) |el| if (el) |e| alloc.free(e);
    for (retained.items) |e| alloc.free(e);
}

const RunArg = struct {
    thread_count: usize,
    scale: usize,
    iter: usize,
    transfer_count: usize,
};

pub fn run(alloc: Allocator, arg: RunArg) !void {
    const thread_count = arg.thread_count;
    const scale = arg.scale;
    const iter = arg.iter;
    const transfer_count = arg.transfer_count;

    var prng = Random.DefaultPrng.init(0xdeadbeef);
    const rand = prng.random();

    // Minus 1, as we also actively use the main thread
    const threads = try alloc.alloc(Thread, thread_count -| 1);
    defer alloc.free(threads);

    const transfer = try alloc.alloc(AtomicSlice, transfer_count);
    @memset(transfer, .{});

    for (0..iter) |_| {
        // Run all workers (including main)
        for (threads) |*thread| {
            const args: Args = .{
                .rand = prng.random(),
                .transfer = transfer,
                .scale = scale,
            };

            thread.* = try Thread.spawn(.{}, worker, .{ alloc, args });
        }
        {
            const args: Args = .{
                .rand = rand,
                .transfer = transfer,
                .scale = scale,
            };

            try worker(alloc, args);
        }
        for (threads) |thread| thread.join();

        // Free half the transfer list
        // We don't have to lock the slice, as we are the only running
        // thread
        for (transfer) |*tmp| if (tmp.slice) |t| {
            if (rand.boolean()) {
                alloc.free(t);
                tmp.slice = null;
            }
        };
    }

    // Free the rest
    for (transfer) |tmp| if (tmp.slice) |t| alloc.free(t);
}

pub fn main() !void {
    _ = &run;
}

const std = @import("std");

const swap = std.mem.swap;

const Random = std.Random;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
