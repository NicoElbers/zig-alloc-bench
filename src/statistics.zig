pub fn TDigest(compression: f64) type {
    const Centroid = struct {
        mean: f64,
        weight: f64,

        pub fn add(s: *@This(), o: @This()) void {
            assert(o.weight >= 0);

            if (s.weight > 0) {
                s.weight += o.weight;
                s.mean += o.weight * (o.mean - s.mean) / s.weight;
            } else {
                s.weight = o.weight;
                s.mean = o.mean;
            }
        }

        pub fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            return lhs.mean < rhs.mean;
        }
    };

    const compression_u: usize = @intFromFloat(@ceil(compression));
    const maxProcessed = 2 * compression_u;
    const maxUnprocessed = 8 * compression_u;

    return struct {
        processed: std.BoundedArray(Centroid, maxProcessed),
        cumulative: std.BoundedArray(f64, maxProcessed + 1),
        unprocessed: std.BoundedArray(Centroid, maxUnprocessed + maxProcessed),
        processedWeight: f64,
        unprocessedWeight: f64,
        min: f64,
        max: f64,
        outliers: usize,

        pub const init: @This() = .{
            .processed = .{},
            .unprocessed = .{},
            .cumulative = .{},
            .processedWeight = 0,
            .unprocessedWeight = 0,
            .min = std.math.floatMax(f64),
            .max = -std.math.floatMax(f64),
            .outliers = 0,
        };

        pub fn add(self: *@This(), value: f64) void {
            assert(std.math.isFinite(value));
            assert(!std.math.isNan(value));

            // Never overflow, otherwise bad things happen
            assert(self.unprocessed.len <= maxUnprocessed);
            defer assert(self.unprocessed.len <= maxUnprocessed);

            self.min = @min(self.min, value);
            self.max = @max(self.max, value);

            self.unprocessed.appendAssumeCapacity(.{ .mean = value, .weight = 1 });
            self.unprocessedWeight += 1;

            if (self.unprocessed.len == maxUnprocessed) {
                self.process();
            }
        }

        pub fn count(self: *@This()) f64 {
            self.process();
            return self.processedWeight;
        }

        pub fn getOutliers(self: *@This()) usize {
            self.process();
            return self.outliers;
        }

        pub fn quantile(self: *@This(), q: f64) f64 {
            self.process();
            self.updateCumulative();

            return quantileRaw(self, q);
        }

        fn quantileRaw(self: *@This(), q: f64) f64 {
            assert(q >= 0);
            assert(q <= 1);

            assert(self.processed.len > 0);

            const processed = &self.processed;
            const cumulative = &self.cumulative;

            if (processed.len == 1) return processed.get(0).mean;

            const index = q * self.processedWeight;
            if (index <= processed.get(0).weight / 2) {
                const zero = processed.get(0);

                return self.min + 2 * index / zero.weight * (zero.mean - self.min);
            }

            var lower: usize = 0;
            while (cumulative.get(lower) < index) : (lower += 1) {}

            if (lower != cumulative.len - 1) {
                const z1 = index - cumulative.get(lower - 1);
                const z2 = cumulative.get(lower) - index;
                return weightedAvg(
                    processed.get(lower - 1).mean,
                    z2,
                    processed.get(lower).mean,
                    z1,
                );
            }

            const z1 = index - self.processedWeight - processed.get(lower - 1).weight / 2;
            const z2 = (processed.get(lower - 1).weight / 2) - z1;
            return weightedAvg(
                processed.get(processed.len - 1).mean,
                z1,
                self.max,
                z2,
            );
        }

        pub fn getMin(self: *@This()) f64 {
            self.process();
            return self.min;
        }

        pub fn getMax(self: *@This()) f64 {
            self.process();
            return self.max;
        }

        fn weightedAvg(v1: f64, w1: f64, v2: f64, w2: f64) f64 {
            return if (v1 <= v2)
                weightedAvgSorted(v1, w1, v2, w2)
            else
                weightedAvgSorted(v2, w2, v1, w1);
        }

        fn weightedAvgSorted(v1: f64, w1: f64, v2: f64, w2: f64) f64 {
            const v = (v1 * w1 + v2 * w2) / (w1 + w2);
            return @max(v1, @min(v, v2));
        }

        fn updateCumulative(self: *@This()) void {
            if (self.cumulative.len > 0 and
                self.cumulative.get(self.cumulative.len - 1) == self.processedWeight)
            {
                return;
            }

            // We need to deal with the entire processed list and 1 more
            comptime assert(self.cumulative.buffer.len == maxProcessed + 1);

            self.cumulative.clear();

            var prev: f64 = 0;
            for (self.processed.slice()) |centroid| {
                const cur = centroid.weight;
                self.cumulative.appendAssumeCapacity(prev + (cur / 2));
                prev += cur;
            }
            self.cumulative.appendAssumeCapacity(prev);
        }

        fn process(self: *@This()) void {
            // At the end of process, unprocessed should be empty
            defer assert(self.unprocessed.len == 0);
            defer assert(self.processed.len <= maxProcessed);

            assert(self.unprocessed.len <= maxUnprocessed);

            if (self.unprocessed.len == 0) return;
            defer self.unprocessed.clear();

            const processed = &self.processed;
            const unprocessed = &self.unprocessed;

            // Put all centroids into the unprocessed buffer and sort
            unprocessed.appendSliceAssumeCapacity(processed.slice());
            processed.clear();

            std.mem.sort(Centroid, unprocessed.slice(), {}, Centroid.lessThan);

            processed.appendAssumeCapacity(unprocessed.get(0));

            self.processedWeight += self.unprocessedWeight;
            self.unprocessedWeight = 0;

            // The meat and potatoes:
            // - Set limits on the weight in 'this bucket'
            // - If this centroid fits in this bucket, add it
            // - Else make this centroid the start of the next bucket
            var prev: f64 = unprocessed.get(0).weight;
            var limit: f64 = self.processedWeight * integratedQ(1);

            for (unprocessed.slice()[1..]) |centroid| {
                const next = prev + centroid.weight;
                defer prev = next;

                if (next <= limit) {
                    (&processed.buffer[processed.len - 1]).add(centroid);
                } else {
                    const k1 = integratedLocation(prev / self.processedWeight);
                    limit = self.processedWeight * integratedQ(k1 + 1);
                    processed.appendAssumeCapacity(centroid);
                }
            }

            // Count outliers
            self.updateCumulative();
            const p25 = self.quantileRaw(0.25);
            const p75 = self.quantileRaw(0.75);

            const iqr = p75 - p25;

            assert(iqr >= 0);

            const lower = p25 - 1.5 * iqr;
            const upper = p75 + 1.5 * iqr;

            for (unprocessed.slice()) |centroid| {
                if (centroid.weight > 1) continue;

                if (lower > centroid.mean or centroid.mean > upper)
                    self.outliers += 1;
            }
        }

        fn integratedQ(p: f64) f64 {
            const pi = std.math.pi;

            return (@sin(@min(p, compression) * pi / compression - pi / 2.0) + 1.0) / 2.0;
        }

        fn integratedLocation(q: f64) f64 {
            const pi = std.math.pi;
            const asin = std.math.asin;

            return compression * (asin(2 * q - 1) + pi / 2.0) / pi;
        }
    };
}

test TDigest {
    var list = [_]f64{
        10109,
        5891,
        160,
        1473,
        251,
        50,
        10991,
        40,
        50,
        40,
        50,
        40,
        40,
        30,
        30,
        1293,
        40,
        70,
        3597,
        1233,
        7714,
        1473,
        461,
        1543,
        5691,
        1112,
        400,
        1873,
        6672,
        471,
        2074,
        7484,
        471,
        1763,
        10920,
        1342,
        451,
        1923,
        14417,
        1362,
        491,
        2425,
        23224,
        611,
        1944,
        44484,
        999999,
    };

    _ = &list;
    // std.sort.insertion(f64, &list, {}, std.sort.asc(f64));

    var prng = std.Random.DefaultPrng.init(0xbadc0de);
    const rand = prng.random();

    var td10 = TDigest(10).init;
    var td50 = TDigest(50).init;
    var td100 = TDigest(100).init;
    var td1000 = TDigest(1000).init;
    for (0..1_000_000 + 1) |_| {
        const v = rand.floatNorm(f64);

        td10.add(v);
        td50.add(v);
        td100.add(v);
        td1000.add(v);

        // td10.add(@floatFromInt(v));
        // td50.add(@floatFromInt(v));
        // td1000.add(@floatFromInt(v));
    }

    std.debug.print("td10 ({d})\n", .{td10.getOutliers()});
    std.debug.print("min: {d}; p50: {d}; max: {d}\n", .{ td10.getMin(), td10.quantile(0.50), td10.getMax() });
    std.debug.print("min: {d}; p90: {d}; max: {d}\n", .{ td10.getMin(), td10.quantile(0.90), td10.getMax() });
    std.debug.print("min: {d}; p99: {d}; max: {d}\n", .{ td10.getMin(), td10.quantile(0.99), td10.getMax() });

    std.debug.print("td50 ({d})\n", .{td50.getOutliers()});
    std.debug.print("min: {d}; p50: {d}; max: {d}\n", .{ td50.getMin(), td50.quantile(0.50), td50.getMax() });
    std.debug.print("min: {d}; p90: {d}; max: {d}\n", .{ td50.getMin(), td50.quantile(0.90), td50.getMax() });
    std.debug.print("min: {d}; p99: {d}; max: {d}\n", .{ td50.getMin(), td50.quantile(0.99), td50.getMax() });

    std.debug.print("td100 ({d})\n", .{td100.getOutliers()});
    std.debug.print("min: {d}; p50: {d}; max: {d}\n", .{ td100.getMin(), td100.quantile(0.100), td100.getMax() });
    std.debug.print("min: {d}; p90: {d}; max: {d}\n", .{ td100.getMin(), td100.quantile(0.90), td100.getMax() });
    std.debug.print("min: {d}; p99: {d}; max: {d}\n", .{ td100.getMin(), td100.quantile(0.99), td100.getMax() });

    std.debug.print("td1000 ({d})\n", .{td1000.getOutliers()});
    std.debug.print("min: {d}; p50: {d}; max: {d}\n", .{ td1000.getMin(), td1000.quantile(0.50), td1000.getMax() });
    std.debug.print("min: {d}; p90: {d}; max: {d}\n", .{ td1000.getMin(), td1000.quantile(0.90), td1000.getMax() });
    std.debug.print("min: {d}; p99: {d}; max: {d}\n", .{ td1000.getMin(), td1000.quantile(0.99), td1000.getMax() });
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
                    break :blk (value / 100) + 1;
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
};

pub const Tally = struct {
    tdigest: TDigest(50) = .init,

    pub const init: Tally = .{};

    pub fn add(self: *@This(), value: f64) void {
        self.tdigest.add(value);
    }

    pub fn getOutliers(self: *@This()) f64 {
        return @floatFromInt(self.tdigest.getOutliers());
    }

    pub fn getMin(self: *@This()) f64 {
        return self.tdigest.getMin();
    }

    pub fn getP50(self: *@This()) f64 {
        return self.tdigest.quantile(0.50);
    }

    pub fn getP90(self: *@This()) f64 {
        return self.tdigest.quantile(0.90);
    }

    pub fn getP99(self: *@This()) f64 {
        return self.tdigest.quantile(0.99);
    }

    pub fn getMax(self: *@This()) f64 {
        return self.tdigest.getMax();
    }

    pub fn getCount(self: *@This()) usize {
        return @intFromFloat(self.tdigest.count());
    }

    pub fn zonable(self: *Tally) Zonable {
        return .{
            .outliers = self.getOutliers(),
            .min = self.getMin(),
            .p50 = self.getP50(),
            .p90 = self.getP90(),
            .p99 = self.getP99(),
            .max = self.getMax(),
        };
    }

    pub const Zonable = struct {
        outliers: f64 = 0,
        min: f64 = 0,
        p50: f64 = 0,
        p90: f64 = 0,
        p99: f64 = 0,
        max: f64 = 0,

        pub const init: Zonable = .{};
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

    pub fn zonable(self: *LazyTally) ?Tally.Zonable {
        return if (self.tally) |*t| t.zonable() else null;
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

    pub fn zonable(self: *FallableTally) Zonable {
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

const std = @import("std");

const assert = std.debug.assert;
