//! Very loosly based on a benchmark by Paul Larson (palarson@microsoft.com)
//! https://github.com/daanx/mimalloc-bench/blob/b517ae367c186be7365d238806b475478637d8f2/bench/larson/larson.cpp

const Arg = struct {
    chunks: usize,
    rounds: usize,
    min_size: usize,
    max_size: usize,
};

fn warmup(alloc: Allocator, rand: Random, arg: Arg, arr: [][]u8) !void {
    for (arr) |*elem| {
        const size = rand.intRangeAtMost(usize, arg.min_size, arg.max_size);

        elem.* = try alloc.alloc(u8, size);
    }
}

fn worker(
    alloc: Allocator,
    rand: Random,
    arg: Arg,
) !void {
    const arr: [][]u8 = try alloc.alloc([]u8, arg.chunks);

    try warmup(alloc, rand, arg, arr);
    defer for (arr) |elem| alloc.free(elem);

    for (0..arg.chunks * arg.rounds) |_| {
        const victim = rand.uintLessThan(usize, arr.len);

        alloc.free(arr[victim]);

        const new_size = rand.intRangeAtMost(usize, arg.min_size, arg.max_size);
        arr[victim] = try alloc.alloc(u8, new_size);

        touchAllocation(rand, arr[victim]);
    }
}

pub const RunArgs = struct {
    min_size: usize,
    max_size: usize,
    chunks: usize,
    num_rounds: usize,
    thread_count: usize,
};

pub fn run(alloc: Allocator, args: RunArgs) !void {
    var prng = Random.DefaultPrng.init(0xdeadbeef);

    const thread_arr = try alloc.alloc(Thread, args.thread_count);
    for (thread_arr) |*thread| {
        prng.jump();
        const rand = prng.random();

        thread.* = try Thread.spawn(.{}, worker, .{
            alloc,
            rand,
            Arg{
                .chunks = args.chunks / args.thread_count,
                .rounds = args.num_rounds,
                .min_size = args.min_size,
                .max_size = args.max_size,
            },
        });
    }
    for (thread_arr) |thread| thread.join();
}

const std = @import("std");
const common = @import("common.zig");

const touchAllocation = common.touchAllocation;

const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Random = std.Random;
