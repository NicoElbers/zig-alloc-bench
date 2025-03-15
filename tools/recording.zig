pub const magic: []const u8 = &.{ 'r', 0xec };

/// The header consists of, in order:
/// - 2 magic bytes `&.{ 'r', 0xec }`
/// - 1 version byte, this is version 1 (`0b1`)
/// - A `u32` consisting of the total amount of updates
/// - A `u32` consisting of the total amount of sequences
/// - N `u32`s consisting of the size per sequence, where N is the total amount
///   of sequences
pub const Header = struct {
    update_count: u32,
    sequences_count: []const u32,

    pub fn parse(alloc: Allocator, file: File) !Header {
        const reader = file.reader();

        { // Magic
            const read_magic = try reader.readBytesNoEof(magic.len);
            if (!std.mem.eql(u8, magic, &read_magic)) return error.InvalidMagic;
        }

        { // Version
            const version = try reader.readByte();
            switch (version) {
                1 => {},
                else => return error.UnknownVersion,
            }
        }

        const update_count = try reader.readInt(u32, .little);

        const sequence_count = try reader.readInt(u32, .little);
        const sequences = try alloc.alloc(u32, sequence_count);

        for (sequences) |*count| {
            count.* = try reader.readInt(u32, .little);
        }

        return .{
            .update_count = update_count,
            .sequences_count = sequences,
        };
    }
};

/// The body consists of, in order:
/// - N times the `Update.Store` struct, as found in `recording_types.zig`, where
///   N is the total amount of updates
/// - N sequences of size Mi `Index`s, as found in `recording_types.zig`, where
///   N is the total amount of sequences and Mi is the ith element in the list
///   of sequence sizes defined in the header.
pub const Body = struct {
    updates: []Update.Playback,
    sequences: []const []const Index,

    pub fn parse(alloc: Allocator, header: Header, file: File) !Body {
        const reader = file.reader();

        const updates = try alloc.alloc(Update.Playback, header.update_count);

        for (updates) |*update| {
            const store = try reader.readStructEndian(Update.Store, .little);
            update.* = .fromStore(store);
        }

        const sequences = try alloc.alloc([]Index, header.sequences_count.len);
        for (sequences, header.sequences_count) |*sequence, len| {
            std.debug.assert(len > 0);
            sequence.* = try alloc.alloc(Index, len);
            for (sequence.*) |*index| {
                index.* = .from(try reader.readInt(u32, .little));
            }
        }

        // Sort by first index
        const lessThanFn = struct {
            pub fn lessThanFn(_: void, lhs: []Index, rhs: []Index) bool {
                return lhs[0].to() < rhs[0].to();
            }
        }.lessThanFn;

        std.mem.sort([]Index, sequences, {}, lessThanFn);

        return .{
            .updates = updates,
            .sequences = sequences,
        };
    }
};

/// The `Index` is the index into all `Update`s. It refers to that specific event.
pub const Index = enum(u32) {
    _,

    pub fn from(idx: usize) Index {
        if (idx > std.math.maxInt(u32)) {
            @panic("Index too large");
        }

        return @enumFromInt(idx);
    }

    pub fn to(index: Index) usize {
        return @intFromEnum(index);
    }
};

pub const Sequence = struct {
    idx: usize = 0,
    updates: []const Index,
};

/// A type safe representation of a pointer.
pub const Pointer = enum(usize) {
    null,
    _,

    pub fn from(ptr: [*]u8) Pointer {
        return @enumFromInt(@intFromPtr(ptr));
    }

    pub fn to(pointer: Pointer) [*]u8 {
        std.debug.assert(pointer != .null);
        return @ptrFromInt(@intFromEnum(pointer));
    }
};

/// An action that can be performed on an allocation. This follows the zig
/// `Allocator` interface, and adds a `transfer` to indicate that the allocation
/// was transfered to another thread.
pub const Action = enum(u8) {
    alloc,
    remap,
    resize,
    free,
    transfer,

    pub const Playback = union(enum) {
        alloc,
        remap,
        resize,
        free,
        transfer: Value(bool),

        pub fn fromAction(a: Action) Playback {
            return switch (a) {
                .alloc => .alloc,
                .remap => .remap,
                .resize => .resize,
                .free => .free,
                .transfer => .{ .transfer = .init(false) },
            };
        }
    };
};

/// An update is the full context of a modification to an allocation passing through
/// the `Allocator` interface, including the size, alignment, action that took place
/// and the thread ID it happened on.
pub const Update = struct {
    action: Action,
    alignm: Alignment,
    tid: Id,
    size: u32,

    /// A mimized verion of `Update` which loses the thread ID, as that is now
    /// encoded in `transfer` actions.
    pub const Store = extern struct {
        action: Action,
        alignm_log2: u8,
        size: u32,

        pub fn fromUpdate(u: Update) Store {
            return .{
                .action = u.action,
                .alignm_log2 = @intFromEnum(u.alignm),
                .size = u.size,
            };
        }
    };

    pub const Playback = struct {
        pointer: Pointer = .null,
        action: Action.Playback,
        alignm: Alignment,
        size: u32,

        pub fn fromStore(u: Store) Playback {
            return .{
                .action = .fromAction(u.action),
                .alignm = @enumFromInt(u.alignm_log2),
                .size = u.size,
            };
        }
    };
};

pub const RecordingAllocator = @import("RecordingAllocator.zig");

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const File = std.fs.File;
const Thread = std.Thread;
const Id = Thread.Id;
const Value = std.atomic.Value;
