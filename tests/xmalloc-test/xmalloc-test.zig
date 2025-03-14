//! \file   test-malloc_test.c
//! \author C. Lever and D. Boreham, Christian Eder ( ederc@mathematik.uni-kl.de )
//! \date   2000
//! \brief  Test file for xmalloc. This is a multi-threaded test system by
//!         Lever and Boreham. It is first noted in their paper "malloc()
//!         Performance in a Multithreaded Linux Environment", appeared at the
//!         USENIX 2000 Annual Technical Conference: FREENIX Track.
//!         This file is part of XMALLOC, licensed under the GNU General
//!         Public License version 3. See COPYING for more information.
//!
//! Ported to Zig and modified for this benchmark runner by Nico Elbers

const possible_sizes = [_]usize{
    8,
    12,
    16,
    24,
    32,
    48,
    64,
    96,
    128,
    192,
    256,
    (256 * 3) / 2,
    512,
    (512 * 3) / 2,
    1024,
    (1024 * 3) / 2,
    2048,
};
const OBJECTS_PER_BATCH = 4096;

const BatchItem = struct {
    next_batch: ?*BatchItem,
    objects: [OBJECTS_PER_BATCH][]u8,
};

const BatchList = struct {
    limit: usize,
    count: usize = 0,
    list: ?*BatchItem = null,
    to_alloc: Value(u64),
    to_free: u64,
    mutex: Mutex = .{},
    empty: Condition = .{},
    full: Condition = .{},

    pub fn claimSlot(self: *BatchList) bool {
        var old = self.to_alloc.load(.acquire);
        if (old <= 0) return false;

        while (self.to_alloc.cmpxchgWeak(old, old - 1, .release, .monotonic)) |curr| {
            old = curr;
            if (old <= 0) return false;
        }

        return true;
    }

    pub fn enqueue(self: *BatchList, batch: *BatchItem) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count >= self.limit) {
            self.full.wait(&self.mutex);
        }

        defer self.empty.signal();
        defer self.count += 1;

        if (self.list) |b| {
            batch.next_batch = b;
        } else {
            batch.next_batch = null;
        }

        self.list = batch;
    }

    pub fn dequeue(self: *BatchList) ?*BatchItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.list == null and self.to_free > 0) {
            self.empty.wait(&self.mutex);
        }

        if (self.list) |b| {
            defer self.full.signal();
            defer self.count -= 1;
            defer self.to_free -= 1;

            self.list = b.next_batch;
            b.next_batch = null;

            return b;
        } else {
            self.empty.signal();
            return null;
        }
    }
};

const Worker = struct {
    alloc: Thread,
    release: Thread,
};

fn memAllocator(alloc: Allocator, list: *BatchList, rand: Random) !void {
    while (list.claimSlot()) {
        const batch: *BatchItem = try alloc.create(BatchItem);

        for (&batch.objects, 0..) |*e, i| {
            const idx = rand.intRangeLessThan(usize, 0, possible_sizes.len);
            const size = possible_sizes[idx];
            e.* = try alloc.alloc(u8, size);
            @memset(e.*[0..@min(128, size)], @intCast(i % 256));
        }

        list.enqueue(batch);
    }
}

fn memReleaser(alloc: Allocator, list: *BatchList) void {
    while (list.dequeue()) |batch| {
        defer alloc.destroy(batch);
        for (batch.objects) |e| alloc.free(e);
    }
}

pub const Args = struct {
    workers: usize,
    batches: u64,
    limit: usize,
};

pub fn run(alloc: Allocator, args: Args) !void {
    const workers = try alloc.alloc(Worker, args.workers);
    defer alloc.free(workers);

    var prng = Random.DefaultPrng.init(0xdeadbeef);
    var list: BatchList = .{
        .limit = args.limit,
        .to_alloc = .init(args.batches),
        .to_free = args.batches,
    };

    for (workers) |*worker| {
        const rand = prng.random();

        worker.alloc = try Thread.spawn(.{}, memAllocator, .{ alloc, &list, rand });
        worker.release = try Thread.spawn(.{}, memReleaser, .{ alloc, &list });
    }

    for (workers) |worker| {
        worker.alloc.join();
        worker.release.join();
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Random = std.Random;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const RwLock = Thread.RwLock;
const Condition = Thread.Condition;
const Value = std.atomic.Value;
