/// A constant memory algorithm that estimates quanitiles, based on:
/// https://aakinshin.net/posts/p2-quantile-estimator-intro/
pub fn P2Quantiles(comptime p: f64) type {
    assert(p >= 0);
    assert(p <= 1);

    return struct {
        n: [5]f64,
        q: [5]f64,
        count: usize,

        const init: @This() = .{
            .q = undefined,
            .n = .{ 0, 1, 2, 3, 4 },
            .count = 0,
        };

        pub fn add(self: *@This(), value: f64) void {
            // Makes the math more readable
            const q = &self.q;
            const n = &self.n;
            const count = self.count;

            defer self.count += 1;

            // First 5 values are for initialization
            if (self.count < 5) {
                q[self.count] = value;

                if (self.count == 4) {
                    // Perform actual initialization

                    // For 5 elements there's no problem using insertion sort
                    std.sort.insertion(f64, &self.q, {}, std.sort.asc(f64));
                }

                return;
            }

            // Get the quantiles we're updating? TODO: verify
            const k: usize = blk: {
                if (value < q[0]) {
                    q[0] = value;
                    break :blk 0;
                } else if (value < q[1])
                    break :blk 0
                else if (value < q[2])
                    break :blk 1
                else if (value < q[3])
                    break :blk 2
                else if (value < q[4])
                    break :blk 3
                else {
                    q[4] = value;
                    break :blk 3;
                }
            };

            // We're going to update all quantiles after k, so increment their
            // counters
            for (k + 1..5) |i| n[i] += 1;

            // How much they want to change? TODO: verify
            const count_f: f64 = @floatFromInt(count);
            const ns: [3]f64 = .{
                count_f * p / 2,
                count_f * p,
                count_f * (1 + p) / 2,
            };

            // The meat and potatoes that I do not understand
            inline for (1..4) |i| {
                // Get the diff
                const d: f64 = ns[i - 1] - n[i];

                if ((d >= 1 and n[i + 1] - n[i] > 1) or
                    (d <= -1 and (n[i - 1] - n[i]) < -1))
                {
                    // Get the sign for some reason
                    const dInt = std.math.sign(d);

                    // Compute some parabolic something
                    const qs = self.parabolic(i, dInt);

                    if (!std.math.isFinite(dInt)) {
                        std.debug.panicExtra(null, "qs: {d}; dInt: {d}", .{ qs, dInt });
                    }

                    // If qs falls inside this 'bucket' we take it
                    if (q[i - 1] < qs and qs < q[i + 1])
                        q[i] = qs
                    else
                        // Else linearly interpolate?? TODO: verify
                        q[i] = self.linear(i, dInt);

                    n[i] += dInt;
                }
            }
        }

        fn parabolic(self: *const @This(), i: usize, d: f64) f64 {
            const q = &self.q;
            const n = &self.n;

            // zig fmt: off
            return q[i] + d / (n[i + 1] - n[i - 1]) * (
                (n[i] - n[i - 1] + d) * (q[i + 1] - q[i]) / (n[i + 1] - n[i]) +
                (n[i + 1] - n[i] - d) * (q[i] - q[i - 1]) / (n[i] - n[i - 1])
            );
            // zig fmt: on
        }

        fn linear(self: *const @This(), i: usize, d: f64) f64 {
            const q = &self.q;
            const n = &self.n;

            const d_u: isize = @intFromFloat(d);

            const du_idx: usize = @intCast(@as(isize, @intCast(i)) + d_u);

            return q[i] + d * (q[du_idx] - q[i]) / (n[du_idx] - n[i]);
        }

        pub fn percentile(self: *const @This()) f64 {
            const count = self.count;
            const q = &self.q;

            assert(self.isValid());

            return if (count <= 5) blk: {
                @branchHint(.unlikely);

                const count_f: f64 = @floatFromInt(count);
                const idx: usize = @intFromFloat(@floor(p * count_f));

                break :blk q[idx];
            } else q[2];
        }

        pub fn min(self: *const @This()) f64 {
            assert(self.isValid());

            return self.q[0];
        }
        pub fn max(self: *const @This()) f64 {
            const count = self.count;
            const q = &self.q;

            assert(self.isValid());

            return if (count < 5)
                q[count - 1]
            else
                q[4];
        }

        pub fn isValid(self: *const @This()) bool {
            return self.count > 0;
        }
    };
}

test P2Quantiles {
    var rng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rand = rng.random();

    for (0..100) |_| {
        var estimator = P2Quantiles(0.5).init;
        var timer = std.time.Timer.start() catch unreachable;
        for (0..1_000_000) |_| {
            estimator.add(rand.floatNorm(f64));
        }
        const tim = timer.read();

        std.debug.print("res: {?d} : {d} us\n{any}\n", .{ estimator.percentile(), tim / std.time.ns_per_us, estimator });
    }
}

pub const Unit = enum {
    time,
    count,
    counter,
    memory,
    percent,

    pub fn convert(unit: @This(), value: f64) struct { f64, [3]u8 } {
        var suffix: [3]u8 = @splat(' ');
        const val = blk: switch (unit) {
            .percent => {
                if (@abs(value) < 200) {
                    suffix[0] = '%';
                    break :blk value;
                } else {
                    suffix[0] = 'x';
                    break :blk value / 100;
                }
            },
            .count, .counter => {
                var limit: f64 = 1;
                inline for (.{ "", "K", "M", "G", "T", "P" }) |name| {
                    defer limit *= 1000;
                    assert(std.math.isNormal(limit));

                    if (value < limit * 1000) {
                        suffix[0..name.len].* = name.*;
                        break :blk value / limit;
                    }
                }
                suffix[0] = 'P';
                break :blk value / limit;
            },
            .memory => {
                var limit: f64 = 1;
                inline for (.{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" }) |name| {
                    defer limit *= 1024;
                    assert(std.math.isNormal(limit));

                    if (value < limit * 1000) {
                        suffix[0..name.len].* = name.*;
                        break :blk value / limit;
                    }
                }
                suffix[0..3].* = "PiB".*;
                break :blk value / limit;
            },
            .time => {
                var limit: f64 = 1;
                inline for (
                    .{ 1000, 1000, 1000, 60, 60, 24, 7 },
                    .{ "ns", "us", "ms", "s", "min", "h", "d" },
                ) |threshold, name| {
                    defer limit *= threshold;

                    if (value < limit * threshold) {
                        suffix[0..name.len].* = name.*;
                        break :blk value / limit;
                    }
                }
                suffix[0..3].* = "day".*;
                break :blk value / limit;
            },
        };

        return .{ val, suffix };
    }

    pub fn write(unit: @This(), writer: File, prefix: []const u8, value: f64) !void {
        const val, const suffix = unit.convert(value);

        try writer.writer().print("- {s}: {d: >6.2} {s}\n", .{ prefix, val, suffix });
    }
};

pub const Tally = struct {
    p50: P2Quantiles(0.50) = .init,
    p90: P2Quantiles(0.90) = .init,
    p99: P2Quantiles(0.99) = .init,
    outliers: usize = 0,

    pub const init: Tally = .{};

    pub fn add(self: *@This(), value: f64) void {
        self.p50.add(value);
        self.p90.add(value);
        self.p99.add(value);

        if (self.getCount() < 5) return;

        // MAD: https://en.wikipedia.org/wiki/Median_absolute_deviation
        const tall_to_mad = 1.2816 * 1.4826;
        const threshold = 3;

        const p50 = self.getP50();
        const p90 = self.getP90();
        const mad = (p90 - p50) / tall_to_mad;

        const lower = p50 - threshold * mad;
        const upper = p50 + threshold * mad;

        if (value < lower or value > upper) self.outliers += 1;
    }

    pub fn getOutliers(self: *const @This()) f64 {
        return (@as(f64, @floatFromInt(self.outliers)) / @as(f64, @floatFromInt(self.getCount()))) * 100;
    }

    pub fn getMin(self: *const @This()) f64 {
        return self.p50.min();
    }

    pub fn getP50(self: *const @This()) f64 {
        return self.p50.percentile();
    }

    pub fn getP90(self: *const @This()) f64 {
        return self.p90.percentile();
    }

    pub fn getP99(self: *const @This()) f64 {
        return self.p99.percentile();
    }

    pub fn getMax(self: *const @This()) f64 {
        return self.p50.max();
    }

    pub fn getCount(self: *const @This()) usize {
        return self.p50.count;
    }

    pub fn isValid(self: *const @This()) bool {
        return self.p50.isValid();
    }

    pub fn zonable(self: *const Tally) Zonable {
        assert(self.isValid());

        return .{
            .min = self.getMin(),
            .p50 = self.getP50(),
            .p90 = self.getP90(),
            .p99 = self.getP99(),
            .max = self.getMax(),
        };
    }

    pub const Zonable = struct {
        min: f64,
        p50: f64,
        p90: f64,
        p99: f64,
        max: f64,
    };
};

pub const LazyTally = struct {
    tally: ?Tally = null,

    pub const init: LazyTally = .{};

    fn create(self: *@This()) void {
        @branchHint(.unlikely);
        self.tally = .init;
    }

    pub fn add(self: *@This(), value: f64) void {
        if (self.tally == null) self.create();

        self.tally.?.add(value);
    }

    pub fn getOutliers(self: *const @This()) f64 {
        return self.tally.?.getOutliers();
    }

    pub fn getMin(self: *const @This()) f64 {
        return self.tally.?.getMin();
    }

    pub fn getP50(self: *const @This()) f64 {
        return self.tally.?.getP50();
    }

    pub fn getP90(self: *const @This()) f64 {
        return self.tally.?.getP90();
    }

    pub fn getP99(self: *const @This()) f64 {
        return self.tally.?.getP99();
    }

    pub fn getMax(self: *const @This()) f64 {
        return self.tally.?.getMax();
    }

    pub fn getCount(self: *const @This()) usize {
        return self.tally.?.getCount();
    }

    pub fn isValid(self: *const @This()) bool {
        return self.tally.?.isValid();
    }

    pub fn write(self: *const @This(), file: File, unit: Unit, width: usize, prefix: []const u8) !void {
        if (self.tally == null) {
            @branchHint(.unlikely);
            return;
        }

        return self.tally.?.write(file, unit, width, prefix);
    }

    pub fn zonable(self: *const LazyTally) ?Tally.Zonable {
        return if (self.tally) |t| t.zonable() else null;
    }
};

pub const FallableTally = struct {
    success: LazyTally = .init,
    failure: LazyTally = .init,

    pub fn addSuccess(self: *FallableTally, value: f64) void {
        self.success.add(value);
    }

    pub fn addFailure(self: *FallableTally, value: f64) void {
        self.failure.add(value);
    }

    pub fn write(self: *const @This(), file: File, unit: Unit, width: usize, comptime prefix: []const u8) !void {
        try self.success.write(file, unit, width, prefix ++ " success");
        try self.failure.write(file, unit, width, prefix ++ " failure");
    }

    pub fn zonable(self: *const FallableTally) Zonable {
        return .{
            .success = self.success.zonable(),
            .failure = self.failure.zonable(),
        };
    }

    pub const Zonable = struct {
        success: ?Tally.Zonable,
        failure: ?Tally.Zonable,
    };

    pub const init: FallableTally = .{};
};

pub const Profiling = struct {
    allocations: FallableTally = .init,
    resizes: FallableTally = .init,
    remaps: FallableTally = .init,
    frees: LazyTally = .init,

    pub fn zonable(self: *const Profiling) Zonable {
        return .{
            .allocations = self.allocations.zonable(),
            .resizes = self.resizes.zonable(),
            .remaps = self.remaps.zonable(),
            .frees = self.frees.zonable(),
        };
    }

    pub const Zonable = struct {
        allocations: FallableTally.Zonable,
        resizes: FallableTally.Zonable,
        remaps: FallableTally.Zonable,
        frees: ?Tally.Zonable,
    };

    pub const init: Profiling = .{};
};

pub const Run = struct {
    test_info: TestInformation,
    constr_info: ContructorInformation,
    runs: usize = 0,
    time: Tally = .init,
    max_rss: Tally = .init,
    cache_misses: Tally = .init,
    profiling: Profiling = .init,

    pub fn zonable(self: *const Run, profiling: bool) Zonable {
        return .{
            .runs = self.runs,
            .test_info = self.test_info.zonable(),
            .constr_info = self.constr_info.zonable(),
            .time = self.time.zonable(),
            .max_rss = self.max_rss.zonable(),
            .cache_miss_percent = self.cache_misses.zonable(),
            .profiling = if (profiling) self.profiling.zonable() else null,
        };
    }

    pub const Zonable = struct {
        runs: usize,
        test_info: TestInformation.Zonable,
        constr_info: ContructorInformation.Zonable,
        time: Tally.Zonable,
        max_rss: Tally.Zonable,
        cache_miss_percent: Tally.Zonable,
        profiling: ?Profiling.Zonable,
    };

    pub fn init(test_info: TestInformation, constr_info: ContructorInformation) Run {
        return .{
            .test_info = test_info,
            .constr_info = constr_info,
        };
    }
};

const std = @import("std");
const runner = @import("runner.zig");

const TestInformation = runner.TestInformation;
const ContructorInformation = runner.ContructorInformation;

const File = std.fs.File;

const assert = std.debug.assert;
