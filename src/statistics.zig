pub const Performance = switch (native_os) {
    .linux => struct {
        fds: [events.len]posix.fd_t = @splat(-1),

        const linux = os.linux;
        const PERF = linux.PERF;

        pub const Res = extern struct {
            cache_misses: usize,
            cache_references: usize,

            pub fn getCacheMissPercent(self: Res) ?f128 {
                const cm: f128 = @floatFromInt(self.cache_misses);
                const cr: f128 = @floatFromInt(self.cache_references);
                return (cm / cr) * 100;
            }
        };

        const Measurement = struct {
            count: PERF.COUNT.HW = .CPU_CYCLES,
            name: []const u8 = &.{},
        };

        const events: []const Measurement = &.{
            .{ .name = "cache_misses", .count = .CACHE_MISSES },
            .{ .name = "cache_references", .count = .CACHE_REFERENCES },
        };

        comptime {
            assert(std.meta.fields(Res).len == events.len);
        }

        pub fn init() !@This() {
            var self: Performance = .{};

            for (events, 0..) |event, i| {
                var attr: linux.perf_event_attr = .{
                    .type = PERF.TYPE.HARDWARE,
                    .config = @intFromEnum(event.count),
                    .flags = .{
                        .disabled = true,
                        .exclude_kernel = true,
                        .exclude_hv = true,
                        .inherit = true,
                        .enable_on_exec = true,
                    },
                };

                self.fds[i] = try posix.perf_event_open(
                    &attr,
                    0,
                    -1,
                    self.fds[0],
                    0,
                );
            }

            return self;
        }

        fn ioctl(self: *const @This(), req: u32, arg: usize) usize {
            return linux.ioctl(self.fds[0], req, arg);
        }

        pub fn reset(self: @This()) void {
            _ = self.ioctl(PERF.EVENT_IOC.RESET, PERF.IOC_FLAG_GROUP);
            _ = self.ioctl(PERF.EVENT_IOC.ENABLE, PERF.IOC_FLAG_GROUP);
        }

        pub fn read(self: @This()) !Res {
            _ = self.ioctl(PERF.EVENT_IOC.DISABLE, 0);

            var res: Res = undefined;

            inline for (self.fds, events) |fd, event| {
                var val: usize = undefined;
                const n = try posix.read(fd, mem.asBytes(&val));
                assert(n == @sizeOf(usize));

                @field(res, event.name) = val;
            }

            return res;
        }

        pub fn deinit(self: *@This()) void {
            for (&self.fds) |*fd| {
                std.posix.close(fd.*);
                fd.* = -1;
            }

            self.* = undefined;
        }
    },
    else => struct {
        pub const Res = extern struct {
            pub fn getCacheMissPercent(_: Res) ?f128 {
                return null;
            }
        };

        pub fn init() !@This() {}
        pub fn reset(_: @This()) void {}
        pub fn read(_: @This()) Res {}
        pub fn deinit(_: *@This()) void {}
    },
};

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const os = std.os;
const mem = std.mem;

const assert = std.debug.assert;

const native_os = builtin.os.tag;
