pub const default =
    correctness ++
    micro ++
    bench ++
    playback;

pub const correctness = @import("correctness.zig").correctness;
pub const micro = @import("micro.zig").micro;
pub const playback = @import("playback.zig").playbacks;
pub const bench = @import("bench.zig").bench;
