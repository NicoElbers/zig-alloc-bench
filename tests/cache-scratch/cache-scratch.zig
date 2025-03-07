//!/-*-C++-*-//////////////////////////////////////////////////////////////////
//!
//! Hoard: A Fast, Scalable, and Memory-Efficient Allocator
//!        for Shared-Memory Multiprocessors
//! Contact author: Emery Berger, http://www.cs.umass.edu/~emery
//!
//! This library is free software; you can redistribute it and/or modify
//! it under the terms of the GNU Library General Public License as
//! published by the Free Software Foundation, http://www.fsf.org.
//!
//! This library is distributed in the hope that it will be useful, but
//! WITHOUT ANY WARRANTY; without even the implied warranty of
//! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//! Library General Public License for more details.
//!
//!////////////////////////////////////////////////////////////////////////////
//!
//! Ported to Zig and modified for this benchmark runner by Nico Elbers

const WorkerArg = struct {
    size: usize,
    iterations: usize,
    repetitions: usize,
};

fn scratch(alloc: Allocator, arg: *WorkerArg) !void {
    // Repeatedly do the following:
    //   malloc a given-sized object,
    //   repeatedly write on it,
    //   then free it.
    for (0..arg.iterations) |_| {
        const obj = try alloc.alloc(u8, arg.size);
        defer alloc.free(obj);

        for (0..arg.repetitions) |_| {
            for (0..arg.size) |k| {
                obj[k] = @truncate(k);

                // Cannot do volatile u8 in zig, therefore we use a pointer
                const ch: *volatile u8 = &obj[k];
                ch.* +%= 1;

                // Not in the original benchmark, but ensure correctness
                // in safe modes
                assert(obj[k] == @as(u8, @truncate(k)) +% 1);
            }
        }
    }
}

pub const Args = struct {
    thread_count: usize,
    iterations: usize,
    obj_size: usize,
    repetitions: usize,
    concurrency: usize = 0, // Unused on linux
};

pub fn run(alloc: Allocator, args: Args) !void {
    const worker_args = try alloc.alloc(WorkerArg, args.thread_count);
    defer alloc.free(worker_args);

    for (worker_args) |*arg| {
        arg.* = .{
            .size = args.obj_size,
            .repetitions = args.repetitions / args.thread_count,
            .iterations = args.iterations,
        };
    }

    const threads = try alloc.alloc(Thread, args.thread_count);
    defer alloc.free(threads);

    for (threads, worker_args) |*thread, *arg| {
        thread.* = try Thread.spawn(.{}, scratch, .{ alloc, arg });
    }

    for (threads) |thread| {
        thread.join();
    }
}

const std = @import("std");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Thread = std.Thread;
