fn parse(arena: *ArenaAllocator, file_path: []const []const u8) !Body {
    const alloc = arena.allocator();

    const path = try std.fs.path.joinZ(alloc, file_path);
    const file = try std.fs.cwd().openFileZ(path, .{});
    defer file.close();

    const header: Header = try .parse(alloc, file);
    return try .parse(alloc, header, file);
}

fn playback(alloc: Allocator, thread_count: usize, file_path: []const []const u8) !void {
    assert(thread_count > 0);

    var arena: ArenaAllocator = .init(alloc);
    const arena_alloc = arena.allocator();
    defer arena.deinit();

    const record = try parse(&arena, file_path);

    const thread_sequences: []const []Sequence = blk: {
        assert(record.sequences.len > thread_count);

        const sequences_per_thread = record.sequences.len / thread_count;
        const sequences_remaining = record.sequences.len % thread_count;
        assert(sequences_remaining < thread_count);

        const thread_sequences = try arena_alloc.alloc([]Sequence, thread_count);

        for (thread_sequences[0..sequences_remaining]) |*seq|
            seq.* = try arena_alloc.alloc(Sequence, sequences_per_thread + 1);

        for (thread_sequences[sequences_remaining..]) |*seq|
            seq.* = try arena_alloc.alloc(Sequence, sequences_per_thread);

        // Interleave sequences to ensure thread transfers actually transfer
        // threads
        for (record.sequences, 0..) |seq, i| {
            const idx = i / thread_count;
            const thread_idx = i % thread_count;

            thread_sequences[thread_idx][idx] = .{ .updates = seq };
        }

        break :blk thread_sequences;
    };

    const threads = try alloc.alloc(Thread, thread_count);
    defer alloc.free(threads);

    for (threads, thread_sequences) |*t, s| t.* = try .spawn(
        .{},
        playbackThread,
        .{ alloc, s, record.updates },
    );
    for (threads) |t| t.join();
}

fn playbackThread(alloc: Allocator, sequences: []Sequence, updates: []Update.Playback) !void {
    var sequences_completed: usize = 0;

    // var highest_allowed_idx: usize = sequences[0].updates[0].to();

    while (sequences_completed < sequences.len) {
        inner: for (sequences) |*seq| {
            if (seq.idx >= seq.updates.len) continue :inner;

            // if (seq.updates[0].to() > highest_allowed_idx) {
            //     // Always increment to ensure we never get stuck
            //     highest_allowed_idx += 1;
            //     continue :outer;
            // }

            const update = &updates[seq.updates[seq.idx].to()];
            switch (update.action) {
                .alloc => {
                    defer assert(update.pointer != .null);
                    const ret = alloc.rawAlloc(update.size, update.alignm, 0) orelse
                        return error.OutOfMemory;

                    assert(update.pointer == .null);
                    update.pointer = .from(ret);
                },

                .remap => {
                    defer assert(update.pointer != .null);
                    assert(seq.idx > 0);
                    const prev_update = &updates[seq.updates[seq.idx - 1].to()];

                    const mem: []u8 = prev_update.pointer.to()[0..prev_update.size];

                    const ret = alloc.rawRemap(mem, update.alignm, update.size, 0) orelse blk: {
                        // In case remap fails, do the naive alternative

                        const ret = alloc.rawAlloc(update.size, update.alignm, 0) orelse
                            return error.OutOfMemory;

                        const end = @min(prev_update.size, update.size);
                        @memcpy(ret[0..end], mem[0..end]);

                        alloc.rawFree(mem, update.alignm, 0);

                        break :blk ret;
                    };

                    assert(update.pointer == .null);
                    update.pointer = .from(ret);
                },

                .resize => {
                    defer assert(update.pointer != .null);
                    assert(seq.idx > 0);
                    const prev_update = &updates[seq.updates[seq.idx - 1].to()];

                    const mem: []u8 = prev_update.pointer.to()[0..prev_update.size];

                    const resized = alloc.rawResize(mem, update.alignm, update.size, 0);

                    if (!resized) {
                        // In case resize fails, do the naive alternative

                        const ret = alloc.rawAlloc(update.size, update.alignm, 0) orelse
                            return error.OutOfMemory;

                        const end = @min(prev_update.size, update.size);
                        @memcpy(ret[0..end], mem[0..end]);

                        alloc.rawFree(mem, update.alignm, 0);

                        assert(update.pointer == .null);
                        update.pointer = .from(ret);
                    } else {
                        update.pointer = prev_update.pointer;
                    }
                },

                .free => {
                    defer assert(update.pointer == .null);
                    assert(seq.idx > 0);
                    const prev_update = &updates[seq.updates[seq.idx - 1].to()];

                    const mem: []u8 = prev_update.pointer.to()[0..update.size];
                    alloc.rawFree(mem, update.alignm, 0);

                    update.pointer = .null;
                },

                .transfer => |*b| if (seq.idx == 0) {
                    // Transfer is the first update, we need to wait for
                    // it to happen. We do this by continuing the loop
                    // instead of letting it play out and increase the
                    // idx.
                    if (!b.load(.acquire))
                        continue :inner;

                    // From here on the other thread should have set the pointer
                    assert(update.pointer != .null);
                } else {
                    assert(seq.idx > 0);
                    const prev_update = &updates[seq.updates[seq.idx - 1].to()];

                    // Set the pointer for the next thread
                    assert(update.pointer == .null);
                    update.pointer = prev_update.pointer;

                    b.store(true, .release);
                },
            }

            // Increment on success
            // highest_allowed_idx = @max(
            //     highest_allowed_idx,
            //     seq.updates[seq.idx].to(),
            // );

            seq.idx += 1;
            if (seq.idx >= seq.updates.len)
                sequences_completed += 1;
        }
    }
}

pub const playbacks = [_]TestInformation{
    .{
        .name = "Self playback",
        .test_fn = &selfPlayback,
        .timeout_ns = std.time.ns_per_s * 5,
        .charactaristics = .{
            .multithreaded = true,
        },
        .arg = .{ .exponential = .{ .n = 5 } },
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s * 5,
        },
    },
};

const playback_base = "playback";

fn selfPlayback(alloc: Allocator, thread_count: ArgInt) !void {
    try playback(alloc, thread_count, &.{ playback_base, "self.rec" });
}

const std = @import("std");
const runner = @import("runner");
const common = @import("common.zig");
const recording = @import("recording");

const touchAllocation = common.touchAllocation;
const assert = std.debug.assert;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Alignment = std.mem.Alignment;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
const Header = recording.Header;
const Body = recording.Body;
const Update = recording.Update;
const Sequence = recording.Sequence;
const Index = recording.Index;
const Thread = std.Thread;
