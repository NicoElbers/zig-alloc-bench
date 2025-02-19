pub const ForkRetParent = struct {
    pid: posix.pid_t,
    stdin: File,
    stdout: File,
    stderr: File,
    err_pipe: File,
    ipc_read: File,
};

pub const ForkRetChild = struct {
    err_pipe: File,
    ipc_write: File,
};

pub const ForkRet = union(enum) {
    parent: ForkRetParent,
    child: ForkRetChild,
};

/// Abstraction over fork, currently just calls the forkPosix, but I may want
/// to add Windows suport in the future
pub fn fork() !ForkRet {
    return switch (native_os) {
        // Linux has it's own native fork impl
        .linux => forkPosix(),

        // Supported os's if libc is linked yoinked by going to definitions
        // of posix.fork
        .dragonfly,
        .freebsd,
        .ios,
        .macos,
        .netbsd,
        .openbsd,
        .solaris,
        .illumos,
        .tvos,
        .watchos,
        .visionos,
        .haiku,
        => |t| if (link_libc) forkPosix() else @compileError(@tagName(t) ++ " not supported"),

        // In the future, try to create at least a windows alternative
        // maybe wasm would be interesting too idk
        inline else => |t| @compileError(@tagName(t) ++ " not supported"),
    };
}

/// Effectively a copy of `std.process.Child.spawnPosix`, with many features
/// stripped out. This is done for simplicitly, and ease of setting up more
/// intricate communication in the future.
pub fn forkPosix() !ForkRet {
    // Create default pipes
    const stdin_pipe = try posix.pipe();
    errdefer destroyPipe(stdin_pipe);

    const stdout_pipe = try posix.pipe();
    errdefer destroyPipe(stdout_pipe);

    const stderr_pipe = try posix.pipe();
    errdefer destroyPipe(stderr_pipe);

    // Create special IPC pipes
    const ipc_pipe_flags: posix.O = .{ .NONBLOCK = true };
    const err_pipe: [2]posix.fd_t = try posix.pipe2(ipc_pipe_flags);
    errdefer destroyPipe(err_pipe);

    const ipc_pipe_child_to_parent: [2]posix.fd_t = try posix.pipe2(ipc_pipe_flags);
    errdefer destroyPipe(ipc_pipe_child_to_parent);

    const pid_result = try posix.fork();

    if (pid_result == 0) {
        // we are the child

        // Close unused pipe ends
        posix.close(stdin_pipe[1]);
        posix.close(stdout_pipe[0]);
        posix.close(stderr_pipe[0]);
        posix.close(err_pipe[0]);
        posix.close(ipc_pipe_child_to_parent[0]);

        // Setup standard files
        posix.dup2(stdin_pipe[0], posix.STDIN_FILENO) catch |err| forkChildErrReport(.{ .handle = err_pipe[1] }, err);
        posix.close(stdin_pipe[0]);

        posix.dup2(stdout_pipe[1], posix.STDOUT_FILENO) catch |err| forkChildErrReport(.{ .handle = err_pipe[1] }, err);
        posix.close(stdout_pipe[1]);

        posix.dup2(stderr_pipe[1], posix.STDERR_FILENO) catch |err| forkChildErrReport(.{ .handle = err_pipe[1] }, err);
        posix.close(stderr_pipe[1]);

        return .{ .child = .{
            .err_pipe = .{ .handle = err_pipe[1] },
            .ipc_write = .{ .handle = ipc_pipe_child_to_parent[1] },
        } };
    } else {
        // we are the parent, pid result is child pid

        // Close unused pipe ends
        posix.close(stdin_pipe[0]);
        posix.close(stdout_pipe[1]);
        posix.close(stderr_pipe[1]);
        posix.close(err_pipe[1]);
        posix.close(ipc_pipe_child_to_parent[1]);

        return .{ .parent = .{
            .pid = @intCast(pid_result),
            .stdin = .{ .handle = stdin_pipe[1] },
            .stdout = .{ .handle = stdout_pipe[0] },
            .stderr = .{ .handle = stderr_pipe[0] },
            .err_pipe = .{ .handle = err_pipe[0] },
            .ipc_read = .{ .handle = ipc_pipe_child_to_parent[0] },
        } };
    }
}

pub fn destroyPipe(pipe: [2]posix.fd_t) void {
    if (pipe[0] != -1) posix.close(pipe[0]);
    if (pipe[0] != pipe[1]) posix.close(pipe[1]);
}

// Child of fork calls this to report an error to the fork parent.
// Then the child exits.
fn forkChildErrReport(file: File, err: anyerror) noreturn {
    if (@errorReturnTrace()) |st| {
        dumpStackTrace(st.*, file.writer(), .no_color);
    }
    file.writer().print("Error: {s}\n", .{@errorName(err)}) catch {};

    // If we're linking libc, some naughty applications may have registered atexit handlers
    // which we really do not want to run in the fork child. I caught LLVM doing this and
    // it caused a deadlock instead of doing an exit syscall. In the words of Avril Lavigne,
    // "Why'd you have to go and make things so complicated?"
    if (link_libc) {
        // The _exit(2) function does nothing but make the exit syscall, unlike exit(3)
        std.c._exit(1);
    }
    posix.exit(1);
}

pub fn waitOnFork(pid: posix.fd_t, ru: ?*posix.rusage, timeout_ns: ?u64) !Term {
    // If pid 0 is passed in we'll accidentally kill a lot of processes
    // in killPid. So make sure we don't
    assert(pid != 0);

    // If we at any point error, do the safe thing and kill the process
    errdefer killPid(pid, ru);

    const res = if (timeout_ns) |timeout| blk: switch (native_os) {
        .linux => {
            // based on: https://stackoverflow.com/a/65003348
            // Had to error handle myself as zig doesn't provide a wrapper for
            // that annoyingly
            const rc = linux.pidfd_open(pid, 0);
            const pidfd: posix.pid_t = switch (linux.E.init(rc)) {
                .SUCCESS => @intCast(rc),
                .INVAL => unreachable,
                .MFILE => return error.SystemResources,
                .NFILE => return error.SystemResources,
                .NODEV => return error.FilesystemUnavailable,
                .NOMEM => return error.SystemResources,
                .SRCH => return error.ProcessNotFound,
                else => |e| return posix.unexpectedErrno(e),
            };
            defer posix.close(@intCast(rc));

            var pollfd: [1]posix.pollfd = .{.{
                .fd = pidfd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const timespec: posix.timespec = .{
                .sec = @intCast(@divFloor(timeout, std.time.ns_per_s)),
                .nsec = @intCast(@mod(timeout, std.time.ns_per_s)),
            };
            const polled_events = try posix.ppoll(&pollfd, &timespec, null);

            if (polled_events == 1)
                break :blk posix.wait4(pid, 0, ru)
            else {
                killPid(pid, ru);
                return .TimedOut;
            }
        },

        else => {
            var timer = std.time.Timer.start() catch @panic("Required timer support");

            var backoff: struct {
                next_backoff_ns: u64 = 0,
                max_backoff_ns: u64 = std.time.ns_per_ms * 100,

                /// Backoff and increment next_backoff_ns by * 2 + 1
                pub fn backoff(self: *@This()) void {
                    const time = @min(self.next_backoff_ns, self.max_backoff_ns);
                    self.next_backoff_ns = @min(time * 2 + 1, self.max_backoff_ns);

                    std.time.sleep(time);
                }
            } = .{};

            while (timer.read() < timeout) {
                // First we sleep, so that we don't accidentally miss the last wait
                // The first backoff call should return 0 so it's all good
                backoff.backoff();

                const res = posix.wait4(pid, posix.W.NOHANG, ru);

                // The process has been waited on
                if (res.pid != 0) break :blk res;
            }

            killPid(pid, ru);
            return .TimedOut;
        },
    } else posix.wait4(pid, 0, ru);
    assert(res.pid == pid);
    return statusToTerm(res.status);
}

pub fn killPid(pid: posix.pid_t, ru: ?*posix.rusage) void {
    // Killing pid 0 is not good
    assert(pid != 0);

    std.posix.kill(pid, 9) catch {};

    // Even though we killed the process, we still need to wait on it to make
    // sure we don't pile up zombie processes.
    _ = posix.wait4(pid, 0, ru);
}

fn statusToTerm(status: u32) Term {
    return if (posix.W.IFEXITED(status))
        Term{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        Term{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        Term{ .Stopped = posix.W.STOPSIG(status) }
    else
        Term{ .Unknown = status };
}

/// Clone of `std.debug.dumpStackTrace`, however with an argument to specify
/// where to dump it to
pub fn dumpStackTrace(st: std.builtin.StackTrace, out: anytype, tty: std.io.tty.Config) void {
    const tty_config: std.io.tty.Config = switch (tty) {
        .escape_codes => .escape_codes,

        // We cannot use windows colors because they are syscalls
        else => .no_color,
    };

    if (builtin.strip_debug_info) {
        out.print("Unable to dump stack trace: debug info stripped\n", .{}) catch {};
        return;
    }
    const debug_info = std.debug.getSelfDebugInfo() catch |e| {
        out.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(e)}) catch {};
        return;
    };

    std.debug.writeStackTrace(st, out, debug_info, tty_config) catch |e| {
        out.print("Unable to dump stack trace: {s}\n", .{@errorName(e)}) catch {};
        return;
    };
}

pub const Term = union(enum) {
    Exited: u8,
    Signal: u32,
    Stopped: u32,
    TimedOut,
    Unknown: u32,

    pub fn code(self: Term) u32 {
        return switch (self) {
            .TimedOut => 0,
            inline else => |v| v,
        };
    }

    pub fn isFailing(self: Term) bool {
        return self != .Exited or self.Exited != 0;
    }
};

/// Known exit statuses within the project
pub const StatusCode = enum(u8) {
    success = 0,
    genericError = 1,
    outOfMemory = 2,

    pub const Error = error{
        OutOfMemory,
        GenericError,
    };

    pub fn fromStatus(status: StatusCode) Error!void {
        return switch (status) {
            .success => {},
            .genericError => Error.GenericError,
            .outOfMemory => Error.OutOfMemory,
        };
    }

    pub fn toStatus(err: anyerror) StatusCode {
        return switch (err) {
            error.OutOfMemory => .outOfMemory,
            else => .genericError,
        };
    }

    pub fn codeToStatus(code: u8) StatusCode {
        inline for (std.meta.tags(StatusCode)) |status| {
            if (status.toCode() == code) return status;
        }
        return .genericError;
    }

    pub fn errToCode(err: anyerror) u8 {
        return StatusCode.toStatus(err).toCode();
    }

    pub fn toCode(status: StatusCode) u8 {
        return @intFromEnum(status);
    }

    pub fn exitFatal(err: anyerror, file: ?File) noreturn {
        if (file) |f| {
            f.writer().print("Error: {s}\n", .{@errorName(err)}) catch {};
        }
        std.process.exit(StatusCode.errToCode(err));
    }

    pub fn exitSucess() noreturn {
        std.process.exit(StatusCode.success.toCode());
    }
};

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const native_os = builtin.os.tag;
const link_libc = builtin.link_libc;
const assert = std.debug.assert;

const File = std.fs.File;
