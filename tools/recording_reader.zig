pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.log.err("Usage {s} [recording file]", .{args[0]});
        std.process.exit(1);
    }

    const record_file = try std.fs.cwd().openFileZ(args[1], .{});
    defer record_file.close();

    const header: recording.Header = try .parse(alloc, record_file);
    const body: recording.Body = try .parse(alloc, header, record_file);

    std.log.info("updates: {d}, sequences: {d}", .{ header.update_count, header.sequences_count.len });

    std.log.info("Sequences:", .{});
    for (body.sequences, 0..) |seq, i| {
        std.log.info("{d}:", .{i});
        for (seq) |idx| {
            const update = body.updates[idx.to()];

            std.log.info(
                "  {d}: {s} (size: {d})",
                .{ idx.to(), @tagName(update.action), update.size },
            );
        }
    }
}

const std = @import("std");
const recording = @import("recording.zig");

const File = std.fs.File;
const Allocator = std.mem.Allocator;
