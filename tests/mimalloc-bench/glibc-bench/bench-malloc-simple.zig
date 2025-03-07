//! Benchmark malloc and free functions.
//! Copyright (C) 2019-2021 Free Software Foundation, Inc.
//! This file is part of the GNU C Library.
//!
//! The GNU C Library is free software; you can redistribute it and/or
//! modify it under the terms of the GNU Lesser General Public
//! License as published by the Free Software Foundation; either
//! version 2.1 of the License, or (at your option) any later version.
//!
//! The GNU C Library is distributed in the hope that it will be useful,
//! but WITHOUT ANY WARRANTY; without even the implied warranty of
//! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//! Lesser General Public License for more details.
//!
//! You should have received a copy of the GNU Lesser General Public
//! License along with the GNU C Library; if not, see
//! <https://www.gnu.org/licenses/>.
//!
//! Modified by Daan Leijen to fit the mimalloc-bench bench suite and add
//! lifo/fifo free order.
//!
//! Ported to Zig and modified for this benchmark runner by Nico Elbers

// Lowered to run in a reasonable time, was 2_000_000
const num_iters = 2_000;
const num_allocs = 4;
const max_allocs = 1_600;

const Args = struct {
    size: usize,
    arr: [][]u8,
};

fn doBenchmark(alloc: Allocator, args: Args) !void {
    const iters = num_iters;
    const size = args.size;
    const arr = args.arr;

    for (0..iters) |_| {
        for (arr, 0..) |_, i| {
            arr[i] = try alloc.alloc(u8, size);
        }

        // Free half in fifo order
        for (0..arr.len / 2) |i| {
            alloc.free(arr[i]);
        }

        // Free the other half in lifo order
        for (arr.len / 2..arr.len) |i| {
            const idx = (arr.len / 2 + arr.len) - i - 1;
            alloc.free(arr[idx]);
        }
    }
}

pub fn benchMainArena(alloc: Allocator, size: usize) !void {
    const arr = try alloc.alloc([]u8, max_allocs);
    defer alloc.free(arr);

    for (0..num_allocs) |_|
        try doBenchmark(alloc, .{
            .arr = arr,
            .size = size,
        });
}

fn threadTest(alloc: Allocator, arr: [][]u8, size: usize) !void {
    for (0..num_allocs) |_|
        try doBenchmark(alloc, .{
            .arr = arr,
            .size = size,
        });
}

pub fn benchThreaded(alloc: Allocator, size: usize) !void {
    const arr = try alloc.alloc([]u8, max_allocs);
    defer alloc.free(arr);

    const thread = try Thread.spawn(.{}, threadTest, .{ alloc, arr, size });
    thread.join();
}

fn singleAlloc(alloc: Allocator) !void {
    const foo = try alloc.alloc(u8, 16);
    alloc.free(foo);
}

pub fn benchMainWithThread(alloc: Allocator, size: usize) !void {
    const arr = try alloc.alloc([]u8, max_allocs);
    defer alloc.free(arr);

    const thread = try Thread.spawn(.{}, singleAlloc, .{alloc});
    thread.join();

    for (0..num_allocs) |_|
        try doBenchmark(alloc, .{
            .arr = arr,
            .size = size,
        });
}

const std = @import("std");

const Timer = std.time.Timer;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
