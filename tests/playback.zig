/// NOTE: This should be kept in sync with tool/RecordingAllocator.zig's implementation
const Item = union(enum) {
    allocation: Allocation,
    remap: Remap,
    resize: Resize,
    free: Free,

    const Allocation = struct { len: usize, alignment: usize, ret: usize };
    const Remap = struct { ptr: usize, alignment: usize, new_len: usize, ret: usize };
    const Resize = struct { ptr: usize, alignment: usize, new_len: usize };
    const Free = struct { ptr: usize, alignment: usize };
};

const ItemIter = struct {
    split: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *@This()) ?Item {
        const line = self.split.next() orelse return null;
        if (line.len == 0) return null;

        var line_splitter = std.mem.splitScalar(u8, line, ' ');

        return switch (line_splitter.first()[0]) {
            'a' => blk: {
                const out_ptr = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID PTR");
                const len = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID LEN");
                const alignment = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID ALIGN");

                break :blk .{ .allocation = .{
                    .len = len,
                    .alignment = alignment,
                    .ret = out_ptr,
                } };
            },

            'm' => blk: {
                const in_ptr = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID PTR");
                const new_len = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID LEN");
                const alignment = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID ALIGN");
                const ret = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID RET");

                break :blk .{ .remap = .{
                    .ptr = in_ptr,
                    .alignment = alignment,
                    .new_len = new_len,
                    .ret = ret,
                } };
            },

            's' => blk: {
                const in_ptr = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID PTR");
                const new_len = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID LEN");
                const alignment = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID ALIGN");

                break :blk .{ .resize = .{
                    .ptr = in_ptr,
                    .new_len = new_len,
                    .alignment = alignment,
                } };
            },

            'f' => blk: {
                const in_ptr = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID PTR");
                const alignment = std.fmt.parseInt(usize, line_splitter.next().?, 10) catch @panic("INVALID ALIGN");

                break :blk .{ .free = .{
                    .ptr = in_ptr,
                    .alignment = alignment,
                } };
            },

            else => unreachable,
        };
    }
};

pub fn run(path: [:0]const u8, alloc: Allocator) !void {
    const file = try std.fs.cwd().openFileZ(path, .{});
    defer file.close();

    var decompress = try std.compress.xz.decompress(alloc, file.reader());
    defer decompress.deinit();

    // const source = try file.readToEndAllocOptions(alloc, 1 << 27, null, @alignOf(u8), 0);
    const source = try decompress.reader().readAllAlloc(alloc, 1 << 27);
    defer alloc.free(source);

    var iter: ItemIter = .{ .split = std.mem.splitScalar(u8, source, '\n') };

    var prng = std.Random.DefaultPrng.init(0xbadc0de);
    const rand = prng.random();

    var ptr_map: std.AutoHashMapUnmanaged(usize, []u8) = .empty;
    defer ptr_map.deinit(alloc);

    while (iter.next()) |action| switch (action) {
        .allocation => |a| {
            const ptr = alloc.rawAlloc(a.len, .fromByteUnits(a.alignment), 0) orelse return error.Oom;

            try ptr_map.put(alloc, a.ret, ptr[0..a.len]);

            touchAllocation(rand, ptr[0..a.len]);
        },
        .remap => |r| {
            const slice = ptr_map.get(r.ptr) orelse @panic("NOT FOUND");

            const ret: [*]u8 = alloc.rawRemap(slice, .fromByteUnits(r.alignment), r.new_len, 0) orelse blk: {
                const new_slice = try alloc.alloc(u8, r.new_len);
                const end = @min(slice.len, r.new_len);
                @memcpy(new_slice[0..end], slice[0..end]);
                alloc.free(slice);

                break :blk @ptrCast(new_slice);
            };

            touchAllocation(rand, ret[0..r.new_len]);

            if (r.ptr != r.ret) {
                std.debug.assert(ptr_map.remove(r.ptr));
                try ptr_map.put(alloc, r.ret, ret[0..r.new_len]);
            } else {
                try ptr_map.put(alloc, r.ptr, ret[0..r.new_len]);
            }
        },
        .resize => |r| {
            const slice = ptr_map.get(r.ptr) orelse @panic("NOT FOUND");

            const ret = alloc.rawResize(slice, .fromByteUnits(r.alignment), r.new_len, 0);

            if (ret) {
                std.debug.assert(ptr_map.remove(r.ptr));
                try ptr_map.put(alloc, r.ptr, slice.ptr[0..r.new_len]);

                touchAllocation(rand, slice);
            }
        },
        .free => |f| {
            const slice = ptr_map.get(f.ptr) orelse @panic("NOT FOUND");

            alloc.rawFree(slice, .fromByteUnits(f.alignment), 0);

            std.debug.assert(ptr_map.remove(f.ptr));
        },
    };
}

pub const playback = [_]TestInformation{
    .{
        .name = "Self playback",
        .test_fn = &selfPlayback,
        .timeout_ns = std.time.ns_per_s,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s,
        },
    },
    .{
        .name = "Zig compiler playback",
        .test_fn = &zigCompPlayback,
        .timeout_ns = std.time.ns_per_s * 90,
        .rerun = .{
            .run_at_least = 1,
            .run_for_ns = std.time.ns_per_s,
        },
    },
};

fn selfPlayback(alloc: Allocator, _: ArgInt) !void {
    try run("playback/self.rec.xz", alloc);
}

fn zigCompPlayback(alloc: Allocator, _: ArgInt) !void {
    try run("playback/zig-compiler.rec.xz", alloc);
}

const std = @import("std");
const runner = @import("runner");
const common = @import("common.zig");

const touchAllocation = common.touchAllocation;

const File = std.fs.File;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const TestInformation = runner.TestInformation;
const ArgInt = runner.TestArg.ArgInt;
