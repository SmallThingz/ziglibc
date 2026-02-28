const builtin = @import("builtin");
const std = @import("std");
const os = std.posix;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("termios.h");
    @cInclude("sys/time.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/select.h");
});

const cstd = struct {
    extern fn __zreserveFile() callconv(.c) ?*c.FILE;
};

extern "c" fn syscall(number: c_long, ...) c_long;

const trace = @import("trace.zig");

fn errnoConst(comptime name: []const u8, fallback: c_int) c_int {
    if (@hasDecl(c, name)) return @field(c, name);
    return fallback;
}

fn exportInternalSymbol(comptime f: anytype, comptime name: []const u8) void {
    if (builtin.target.ofmt == .coff) {
        @export(f, .{ .name = name });
    } else {
        @export(f, .{ .name = name, .visibility = .hidden });
    }
}

const darwin = if (builtin.os.tag.isDarwin()) struct {
    const mach_port_t = c_uint;
    const kern_return_t = c_int;

    extern "c" fn mach_absolute_time() u64;
    extern "c" fn mach_timebase_info(info: *std.c.mach_timebase_info_data) kern_return_t;
} else struct {};

const darwin_syscall = if (builtin.os.tag.isDarwin()) struct {
    // Stable BSD syscall numbers used by Darwin's syscall(2) ABI.
    const read: c_long = 3;
    const write: c_long = 4;
    const open: c_long = 5;
    const gettimeofday: c_long = 116;
} else struct {};

fn windowsStdHandleFromFd(fd: c_int) ?std.os.windows.HANDLE {
    const process_params = std.os.windows.peb().ProcessParameters;
    return switch (fd) {
        0 => process_params.hStdInput,
        1 => process_params.hStdOutput,
        2 => process_params.hStdError,
        else => null,
    };
}

// C ABI globals: `extern char *optarg; extern int opterr, optind, optopt;`
export var optarg: [*c]u8 = null;
export var opterr: c_int = 1;
export var optind: c_int = 1;
export var optopt: c_int = 0;
var optchar_index: c_int = 1;

const PopenPid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) usize else os.pid_t;

const PopenEntry = struct {
    stream: ?*c.FILE = null,
    pid: PopenPid = 0,
};

var popen_entries: [c.FOPEN_MAX]PopenEntry = [_]PopenEntry{.{}} ** c.FOPEN_MAX;
var popen_mutex: std.Thread.Mutex = .{};

fn registerPopenStream(stream: *c.FILE, pid: PopenPid) bool {
    popen_mutex.lock();
    defer popen_mutex.unlock();
    for (&popen_entries) |*entry| {
        if (entry.stream == null) {
            entry.stream = stream;
            entry.pid = pid;
            return true;
        }
    }
    return false;
}

fn unregisterPopenStream(stream: *c.FILE) ?PopenPid {
    popen_mutex.lock();
    defer popen_mutex.unlock();
    for (&popen_entries) |*entry| {
        if (entry.stream == stream) {
            const pid = entry.pid;
            entry.* = .{};
            return pid;
        }
    }
    return null;
}

fn waitForPidStatus(pid: PopenPid) c_int {
    if (comptime (builtin.os.tag == .windows or builtin.os.tag == .wasi)) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    var status: if (builtin.os.tag.isDarwin()) c_int else u32 = 0;
    while (true) {
        const wait_rc = os.system.waitpid(pid, &status, 0);
        switch (os.errno(wait_rc)) {
            .SUCCESS => {
                if (builtin.os.tag.isDarwin()) return status;
                return @as(c_int, @bitCast(status));
            },
            .INTR => continue,
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }
}

/// Returns some information through these globals
///    extern char *optarg;
///    extern int opterr, optind, optopt;
export fn getopt(argc: c_int, argv: [*][*:0]u8, optstring: [*:0]const u8) callconv(.c) c_int {
    optarg = null;
    if (optind < 1) {
        optind = 1;
        optchar_index = 1;
    }
    trace.log("getopt argc={} argv={*} opstring={f} (err={}, ind={}, opt={})", .{
        argc,
        argv,
        trace.fmtStr(optstring),
        opterr,
        optind,
        optopt,
    });
    if (optind >= argc) {
        trace.log("getopt return -1", .{});
        return -1;
    }
    var arg = argv[@as(usize, @intCast(optind))];
    if (optchar_index <= 1) {
        if (arg[0] != '-' or arg[1] == 0) {
            // Stop option parsing when we reach a non-option argument.
            return -1;
        }
        if (arg[1] == '-' and arg[2] == 0) {
            // End-of-options marker.
            optind += 1;
            optchar_index = 1;
            return -1;
        }
        optchar_index = 1;
    }
    const arg_idx: usize = @intCast(optchar_index);
    if (arg[arg_idx] == 0) {
        optind += 1;
        optchar_index = 1;
        return getopt(argc, argv, optstring);
    }

    const opt_ch = arg[arg_idx];
    const result = c.strchr(optstring, opt_ch) orelse {
        const next_idx = arg_idx + 1;
        if (arg[next_idx] == 0) {
            optind += 1;
            optchar_index = 1;
        } else {
            optchar_index += 1;
        }
        optopt = @as(c_int, opt_ch);
        return '?';
    };

    const takes_arg = result[1] == ':';
    if (takes_arg) {
        const is_optional = result[2] == ':';
        const next_idx = arg_idx + 1;
        if (arg[next_idx] != 0) {
            optarg = @ptrCast(arg + next_idx);
            optind += 1;
            optchar_index = 1;
            return @as(c_int, opt_ch);
        }
        if (is_optional) {
            optarg = null;
            optind += 1;
            optchar_index = 1;
            return @as(c_int, opt_ch);
        }
        if (optind + 1 >= argc) {
            optopt = @as(c_int, opt_ch);
            optind += 1;
            optchar_index = 1;
            return if (optstring[0] == ':') ':' else '?';
        }
        optind += 1;
        arg = argv[@as(usize, @intCast(optind))];
        optarg = @ptrCast(arg);
        optind += 1;
        optchar_index = 1;
        return @as(c_int, opt_ch);
    }

    if (arg[arg_idx + 1] == 0) {
        optind += 1;
        optchar_index = 1;
    } else {
        optchar_index += 1;
    }
    return @as(c_int, opt_ch);
}

fn zwriteRaw(fd: c_int, buf: [*]const u8, nbyte: usize) isize {
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.write, fd, buf, nbyte);
        return if (rc == -1) -1 else @as(isize, @intCast(rc));
    }
    if (builtin.os.tag == .windows) {
        const handle = windowsStdHandleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return -1;
        };
        var total_written: usize = 0;
        while (total_written < nbyte) {
            const remaining = nbyte - total_written;
            const next_len: u32 = @intCast(@min(remaining, @as(usize, std.math.maxInt(u32))));
            var did_write: u32 = 0;
            if (std.os.windows.kernel32.WriteFile(handle, buf + total_written, next_len, &did_write, null) == 0) {
                c.errno = switch (std.os.windows.kernel32.GetLastError()) {
                    .INVALID_HANDLE => errnoConst("EBADF", c.EINVAL),
                    .ACCESS_DENIED => c.EACCES,
                    else => errnoConst("EIO", c.EINVAL),
                };
                return -1;
            }
            total_written += did_write;
            if (did_write == 0) break;
        }
        return @as(isize, @intCast(total_written));
    }
    const rc = os.system.write(fd, buf, nbyte);
    switch (os.errno(rc)) {
        .SUCCESS => return @as(isize, @intCast(rc)),
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

fn zreadRaw(fd: c_int, buf: [*]u8, len: usize) isize {
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.read, fd, buf, len);
        return if (rc == -1) -1 else @as(isize, @intCast(rc));
    }
    trace.log("read fd={} buf={*} len={}", .{ fd, buf, len });
    if (builtin.os.tag == .windows) {
        const handle = windowsStdHandleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return -1;
        };
        const next_len: u32 = @intCast(@min(len, @as(usize, std.math.maxInt(u32))));
        var did_read: u32 = 0;
        if (std.os.windows.kernel32.ReadFile(handle, buf, next_len, &did_read, null) == 0) {
            c.errno = switch (std.os.windows.kernel32.GetLastError()) {
                .INVALID_HANDLE => errnoConst("EBADF", c.EINVAL),
                .BROKEN_PIPE, .HANDLE_EOF => 0,
                else => errnoConst("EIO", c.EINVAL),
            };
            return if (c.errno == 0) 0 else -1;
        }
        return @as(isize, @intCast(did_read));
    }
    const rc = os.system.read(fd, buf, len);
    switch (os.errno(rc)) {
        .SUCCESS => return @as(isize, @intCast(rc)),
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

fn zopenRaw(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int {
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.open, path, oflag, mode);
        return if (rc == -1) -1 else @as(c_int, @intCast(rc));
    }
    if (builtin.os.tag == .windows) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    const flags_bits: u32 = @bitCast(oflag);
    const flags: os.O = @bitCast(flags_bits);
    const rc = os.system.open(path, flags, @as(std.posix.mode_t, @intCast(mode)));
    switch (os.errno(rc)) {
        .SUCCESS => return @as(c_int, @intCast(rc)),
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

export fn write(fd: c_int, buf: [*]const u8, nbyte: usize) callconv(.c) isize {
    return zwriteRaw(fd, buf, nbyte);
}

export fn read(fd: c_int, buf: [*]u8, len: usize) callconv(.c) isize {
    return zreadRaw(fd, buf, len);
}

fn _zopen(path: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.c) c_int {
    return zopenRaw(path, oflag, mode);
}

comptime {
    exportInternalSymbol(&_zopen, "_zopen");
}

// --------------------------------------------------------------------------------
// string
// --------------------------------------------------------------------------------
export fn strdup(s: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    trace.log("strdup '{f}'", .{trace.fmtStr(s)});
    const len = c.strlen(s);
    const optional_new_s = @as(?[*]u8, @ptrCast(c.malloc(len + 1)));
    if (optional_new_s) |new_s| {
        _ = c.strcpy(new_s, s);
    }
    return @as([*:0]u8, @ptrCast(optional_new_s));
}

// --------------------------------------------------------------------------------
// stdlib
// --------------------------------------------------------------------------------
export fn mkstemp(template: [*:0]u8) callconv(.c) c_int {
    return mkostemp(template, 0, 0);
}

export fn mkostemp(template: [*:0]u8, suffixlen: c_int, flags: c_int) callconv(.c) c_int {
    trace.log("mkstemp '{f}'", .{trace.fmtStr(template)});
    if (builtin.os.tag == .windows) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }

    const rand_part: *[6]u8 = blk: {
        const len = c.strlen(template);
        if (6 + suffixlen > len) {
            c.errno = c.EINVAL;
            return -1;
        }
        const rand_part_off = len - @as(usize, @intCast(suffixlen)) - 6;
        break :blk @as(*[6]u8, @ptrCast(template + rand_part_off));
    };

    if (!std.mem.eql(u8, rand_part, "XXXXXX")) {
        c.errno = c.EINVAL;
        return -1;
    }

    const max_attempts = 200;
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        randomizeTempFilename(rand_part);
        const extra_flags: u32 = @as(u32, @intCast(flags));
        const required_flags = os.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        };
        const merged_flags: os.O = @bitCast(@as(u32, @bitCast(required_flags)) | extra_flags);
        const fd = zopenRaw(
            template,
            @as(c_int, @bitCast(@as(u32, @bitCast(merged_flags)))),
            0o600,
        );
        if (fd >= 0) return fd;
        if (attempt >= max_attempts) {
            rand_part.* = [_]u8{ 'X', 'X', 'X', 'X', 'X', 'X' };
            return -1;
        }
    }
}

const filename_char_set =
    "+,-.0123456789=@ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "_abcdefghijklmnopqrstuvwxyz";
fn randToFilenameChar(r: u8) u8 {
    return filename_char_set[r % filename_char_set.len];
}

fn randomizeTempFilename(slice: *[6]u8) void {
    var randoms: [6]u8 = undefined;
    {
        const timestamp = std.time.nanoTimestamp();
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.math.maxInt(u64) & timestamp)));
        prng.random().bytes(&randoms);
    }
    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        slice[i] = randToFilenameChar(randoms[i]);
    }
}

// --------------------------------------------------------------------------------
// stdio
// --------------------------------------------------------------------------------
export fn fileno(stream: *c.FILE) callconv(.c) c_int {
    if (builtin.os.tag == .windows) {
        // this probably isn't right, but might be fine for an initial implementation
        return @as(c_int, @intCast(@intFromPtr(stream.fd)));
    }
    return stream.fd;
}

export fn popen(command: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    trace.log("popen '{f}' mode='{s}'", .{ trace.fmtStr(command), mode });
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }

    const mode_ch = mode[0];
    if (mode_ch != 'r' and mode_ch != 'w') {
        c.errno = c.EINVAL;
        return null;
    }

    var pipe_fds: [2]os.fd_t = undefined;
    const pipe_rc = os.system.pipe(&pipe_fds);
    switch (os.errno(pipe_rc)) {
        .SUCCESS => {},
        else => |e| {
            c.errno = @intFromEnum(e);
            return null;
        },
    }

    const fork_rc = os.system.fork();
    switch (os.errno(fork_rc)) {
        .SUCCESS => {},
        else => |e| {
            _ = os.system.close(pipe_fds[0]);
            _ = os.system.close(pipe_fds[1]);
            c.errno = @intFromEnum(e);
            return null;
        },
    }

    if (fork_rc == 0) {
        if (mode_ch == 'r') {
            _ = os.system.close(pipe_fds[0]);
            if (os.system.dup2(pipe_fds[1], c.STDOUT_FILENO) == -1) {
                os.system.exit(127);
            }
            _ = os.system.close(pipe_fds[1]);
        } else {
            _ = os.system.close(pipe_fds[1]);
            if (os.system.dup2(pipe_fds[0], c.STDIN_FILENO) == -1) {
                os.system.exit(127);
            }
            _ = os.system.close(pipe_fds[0]);
        }

        const shell_path: [*:0]const u8 = "/bin/sh";
        var argv = [_:null]?[*:0]const u8{ shell_path, "-c", command, null };
        const envp = [_:null]?[*:0]const u8{null};
        _ = os.system.execve(shell_path, &argv, @ptrCast(&envp));
        os.system.exit(127);
    }

    const parent_fd = if (mode_ch == 'r') pipe_fds[0] else pipe_fds[1];
    if (mode_ch == 'r') {
        _ = os.system.close(pipe_fds[1]);
    } else {
        _ = os.system.close(pipe_fds[0]);
    }

    const stream = fdopen(@as(c_int, @intCast(parent_fd)), mode) orelse {
        const saved_errno = c.errno;
        _ = os.system.close(parent_fd);
        _ = waitForPidStatus(@as(PopenPid, @intCast(fork_rc)));
        c.errno = saved_errno;
        return null;
    };

    if (!registerPopenStream(stream, @as(PopenPid, @intCast(fork_rc)))) {
        c.errno = errnoConst("EMFILE", c.ENOMEM);
        _ = c.fclose(stream);
        _ = waitForPidStatus(@as(PopenPid, @intCast(fork_rc)));
        return null;
    }
    return stream;
}
export fn pclose(stream: *c.FILE) callconv(.c) c_int {
    const pid = unregisterPopenStream(stream) orelse {
        c.errno = c.EINVAL;
        return -1;
    };
    const close_rc = c.fclose(stream);
    const wait_rc = waitForPidStatus(pid);
    if (wait_rc == -1) return -1;
    if (close_rc != 0) return -1;
    return wait_rc;
}

export fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    trace.log("fdopen {d} mode={s}", .{ fd, mode });
    const file = cstd.__zreserveFile() orelse {
        c.errno = c.ENOMEM;
        return null;
    };
    if (builtin.os.tag == .windows) {
        const handle = windowsStdHandleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return null;
        };
        file.fd = handle;
    } else {
        file.fd = fd;
    }
    file.eof = 0;
    return file;
}

// --------------------------------------------------------------------------------
// unistd
// --------------------------------------------------------------------------------
comptime {
    if (builtin.os.tag != .windows) @export(&close, .{ .name = "close" });
}
fn close(fd: c_int) callconv(.c) c_int {
    trace.log("close {}", .{fd});
    switch (os.errno(os.system.close(fd))) {
        .SUCCESS => return 0,
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

export fn access(path: [*:0]const u8, amode: c_int) callconv(.c) c_int {
    trace.log("access '{f}' mode=0x{x}", .{ trace.fmtStr(path), amode });
    const mode: u32 = @intCast(amode);
    std.posix.accessZ(path, mode) catch |err| {
        c.errno = switch (err) {
            error.AccessDenied => c.EACCES,
            error.PermissionDenied => c.EPERM,
            error.FileNotFound => c.ENOENT,
            error.NameTooLong => errnoConst("ENAMETOOLONG", c.EINVAL),
            error.InputOutput => errnoConst("EIO", c.EINVAL),
            error.SystemResources => c.ENOMEM,
            error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => c.EINVAL,
            error.FileBusy => errnoConst("EBUSY", c.EINVAL),
            error.SymLinkLoop => errnoConst("ELOOP", c.EINVAL),
            error.ReadOnlyFileSystem => errnoConst("EROFS", c.EPERM),
            else => errnoConst("EIO", c.EINVAL),
        };
        return -1;
    };
    return 0;
}

export fn unlink(path: [*:0]const u8) callconv(.c) c_int {
    std.posix.unlinkZ(path) catch |err| {
        c.errno = switch (err) {
            error.AccessDenied => c.EACCES,
            error.PermissionDenied => c.EPERM,
            error.FileBusy => errnoConst("EBUSY", c.EINVAL),
            error.FileSystem => errnoConst("EIO", c.EINVAL),
            error.IsDir => errnoConst("EISDIR", c.EINVAL),
            error.SymLinkLoop => errnoConst("ELOOP", c.EINVAL),
            error.NameTooLong => errnoConst("ENAMETOOLONG", c.EINVAL),
            error.FileNotFound => c.ENOENT,
            error.NotDir => errnoConst("ENOTDIR", c.EINVAL),
            error.SystemResources => c.ENOMEM,
            error.ReadOnlyFileSystem => errnoConst("EROFS", c.EPERM),
            error.InvalidUtf8, error.InvalidWtf8, error.BadPathName => c.EINVAL,
            error.NetworkNotFound => c.ENOENT,
            else => errnoConst("EIO", c.EINVAL),
        };
        return -1;
    };
    return 0;
}

export fn _exit(status: c_int) callconv(.c) noreturn {
    if (builtin.os.tag == .windows) {
        std.os.windows.kernel32.ExitProcess(@as(c_uint, @bitCast(status)));
    }
    if (builtin.os.tag == .wasi) {
        std.os.wasi.proc_exit(status);
    }
    if (builtin.os.tag == .linux and !builtin.single_threaded) {
        // TODO: is this right?
        std.os.linux.exit_group(status);
    }
    os.system.exit(status);
}

export fn isatty(fd: c_int) callconv(.c) c_int {
    if (builtin.os.tag == .windows) {
        const handle = windowsStdHandleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return 0;
        };
        var mode: u32 = 0;
        if (std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0) return 1;
        c.errno = switch (std.os.windows.kernel32.GetLastError()) {
            .INVALID_HANDLE => errnoConst("EBADF", c.EINVAL),
            else => errnoConst("ENOTTY", c.EINVAL),
        };
        return 0;
    }

    var size: c.winsize = undefined;
    switch (os.errno(os.system.ioctl(fd, c.TIOCGWINSZ, @intFromPtr(&size)))) {
        .SUCCESS => return 1,
        .BADF => {
            c.errno = c.ENOTTY;
            return 0;
        },
        else => return 0,
    }
}

// --------------------------------------------------------------------------------
// sys/time
// --------------------------------------------------------------------------------
comptime {
    std.debug.assert(@sizeOf(c.timespec) == @sizeOf(os.timespec));
    if (builtin.os.tag != .windows) {
        std.debug.assert(c.CLOCK_REALTIME == @intFromEnum(os.CLOCK.REALTIME));
    }
}

fn setTimespec(tp: *os.timespec, sec: anytype, nsec: anytype) void {
    if (@hasField(os.timespec, "tv_sec")) {
        tp.tv_sec = @as(@TypeOf(tp.tv_sec), @intCast(sec));
        tp.tv_nsec = @as(@TypeOf(tp.tv_nsec), @intCast(nsec));
    } else {
        tp.sec = @as(@TypeOf(tp.sec), @intCast(sec));
        tp.nsec = @as(@TypeOf(tp.nsec), @intCast(nsec));
    }
}

export fn clock_gettime(clk_id: c.clockid_t, tp: *os.timespec) callconv(.c) c_int {
    if (builtin.os.tag.isDarwin()) {
        if (clk_id == c.CLOCK_REALTIME) {
            var tv: c.timeval = undefined;
            const rc = syscall(darwin_syscall.gettimeofday, &tv, @as(?*anyopaque, null));
            if (rc == -1) return -1;
            setTimespec(tp, tv.tv_sec, tv.tv_usec * 1000);
            return 0;
        }

        const monotonic_id: c.clockid_t = @as(c.clockid_t, @intCast(@intFromEnum(os.CLOCK.MONOTONIC)));
        if (clk_id == monotonic_id) {
            var timebase: std.c.mach_timebase_info_data = undefined;
            if (darwin.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) {
                c.errno = c.EINVAL;
                return -1;
            }
            const ticks = darwin.mach_absolute_time();
            const nanos: u128 = @divFloor(
                @as(u128, ticks) * @as(u128, timebase.numer),
                @as(u128, timebase.denom),
            );
            setTimespec(tp, @divFloor(nanos, std.time.ns_per_s), @mod(nanos, std.time.ns_per_s));
            return 0;
        }

        c.errno = c.EINVAL;
        return -1;
    }

    if (builtin.os.tag == .windows) {
        if (clk_id == c.CLOCK_REALTIME) {
            const ns = std.time.nanoTimestamp();
            const sec = @divFloor(ns, std.time.ns_per_s);
            const nsec = @mod(ns, std.time.ns_per_s);
            setTimespec(tp, sec, nsec);
            return 0;
        }
        c.errno = c.EINVAL;
        return -1;
    }

    const posix_clk_id: os.clockid_t = @enumFromInt(@as(u32, @intCast(clk_id)));
    switch (os.errno(os.system.clock_gettime(posix_clk_id, tp))) {
        .SUCCESS => return 0,
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

export fn gettimeofday(tv: *c.timeval, tz: *anyopaque) callconv(.c) c_int {
    trace.log("gettimeofday tv={*} tz={*}", .{ tv, tz });
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.gettimeofday, tv, tz);
        return if (rc == -1) -1 else 0;
    }
    if (builtin.os.tag == .windows) {
        const ns = std.time.nanoTimestamp();
        tv.tv_sec = @as(@TypeOf(tv.tv_sec), @intCast(@divFloor(ns, std.time.ns_per_s)));
        tv.tv_usec = @as(@TypeOf(tv.tv_usec), @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us)));
        return 0;
    }
    const ns = std.time.nanoTimestamp();
    tv.tv_sec = @as(@TypeOf(tv.tv_sec), @intCast(@divFloor(ns, std.time.ns_per_s)));
    tv.tv_usec = @as(@TypeOf(tv.tv_usec), @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us)));
    return 0;
}

export fn setitimer(which: c_int, value: *const c.itimerval, avalue: *c.itimerval) callconv(.c) c_int {
    trace.log("setitimer which={}", .{which});
    _ = value;
    _ = avalue;
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

// --------------------------------------------------------------------------------
// signal
// --------------------------------------------------------------------------------
export fn sigaction(sig: c_int, act: *const c.struct_sigaction, oact: *c.struct_sigaction) callconv(.c) c_int {
    trace.log("sigaction sig={}", .{sig});
    _ = act;
    _ = oact;
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

// --------------------------------------------------------------------------------
// sys/stat.h
// --------------------------------------------------------------------------------
export fn chmod(path: [*:0]const u8, mode: c.mode_t) callconv(.c) c_int {
    trace.log("chmod '{s}' mode=0x{x}", .{ path, mode });
    if (builtin.os.tag == .windows) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    const rc = os.system.fchmodat(
        os.AT.FDCWD,
        path,
        @as(std.posix.mode_t, @intCast(mode)),
        0,
    );
    switch (os.errno(rc)) {
        .SUCCESS => return 0,
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

fn timespecSeconds(ts: anytype) i64 {
    const ts_ty = @TypeOf(ts);
    if (@hasField(ts_ty, "tv_sec")) {
        return @as(i64, @intCast(ts.tv_sec));
    }
    return @as(i64, @intCast(ts.sec));
}

export fn fstat(fd: c_int, buf: *c.struct_stat) c_int {
    if (builtin.os.tag == .windows) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    var stat_buf: os.Stat = undefined;
    switch (os.errno(os.system.fstat(fd, &stat_buf))) {
        .SUCCESS => {},
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }

    const stat_ty = @TypeOf(stat_buf);
    const atime = if (@hasField(stat_ty, "atim"))
        timespecSeconds(stat_buf.atim)
    else
        timespecSeconds(stat_buf.atimespec);
    const mtime = if (@hasField(stat_ty, "mtim"))
        timespecSeconds(stat_buf.mtim)
    else
        timespecSeconds(stat_buf.mtimespec);
    const ctime = if (@hasField(stat_ty, "ctim"))
        timespecSeconds(stat_buf.ctim)
    else
        timespecSeconds(stat_buf.ctimespec);

    buf.st_dev = @as(@TypeOf(buf.st_dev), @intCast(stat_buf.dev));
    buf.st_ino = @as(@TypeOf(buf.st_ino), @intCast(stat_buf.ino));
    buf.st_mode = @as(@TypeOf(buf.st_mode), @intCast(stat_buf.mode));
    buf.st_nlink = @as(@TypeOf(buf.st_nlink), @intCast(stat_buf.nlink));
    buf.st_uid = @as(@TypeOf(buf.st_uid), @intCast(stat_buf.uid));
    buf.st_gid = @as(@TypeOf(buf.st_gid), @intCast(stat_buf.gid));
    buf.st_rdev = @as(@TypeOf(buf.st_rdev), @intCast(stat_buf.rdev));
    buf.st_size = @as(@TypeOf(buf.st_size), @intCast(stat_buf.size));
    buf.st_atime = @as(@TypeOf(buf.st_atime), @intCast(atime));
    buf.st_mtime = @as(@TypeOf(buf.st_mtime), @intCast(mtime));
    buf.st_ctime = @as(@TypeOf(buf.st_ctime), @intCast(ctime));
    buf.st_blksize = @as(@TypeOf(buf.st_blksize), @intCast(stat_buf.blksize));
    buf.st_blocks = @as(@TypeOf(buf.st_blocks), @intCast(stat_buf.blocks));
    return 0;
}

export fn umask(mode: c.mode_t) callconv(.c) c.mode_t {
    trace.log("umask 0x{x}", .{mode});
    if (builtin.os.tag != .linux) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return mode;
    }
    const old_mode = std.os.linux.syscall1(.umask, @as(usize, @intCast(mode)));
    return @as(c.mode_t, @intCast(old_mode));
}

// --------------------------------------------------------------------------------
// libgen
// --------------------------------------------------------------------------------
export fn basename(path: ?[*:0]u8) callconv(.c) [*:0]u8 {
    trace.log("basename {f}", .{trace.fmtStr(path)});
    const path_slice = std.mem.span(path orelse return @as([*:0]u8, @ptrFromInt(@intFromPtr("."))));
    const name = std.fs.path.basename(path_slice);
    const mut_ptr = @as([*:0]u8, @ptrFromInt(@intFromPtr(name.ptr)));
    if (name.len == 0) {
        if (path_slice.ptr[0] == '/') {
            path_slice.ptr[1] = 0;
            return path_slice.ptr;
        }
        return @as([*:0]u8, @ptrFromInt(@intFromPtr(".")));
    }
    if (mut_ptr[name.len] != 0) mut_ptr[name.len] = 0;
    return mut_ptr;
}

// --------------------------------------------------------------------------------
// termios
// --------------------------------------------------------------------------------
export fn tcgetattr(fd: c_int, ios: *std.os.linux.termios) callconv(.c) c_int {
    switch (os.errno(std.os.linux.tcgetattr(fd, ios))) {
        .SUCCESS => return 0,
        else => |errno| {
            c.errno = @intFromEnum(errno);
            return -1;
        },
    }
}

export fn tcsetattr(
    fd: c_int,
    optional_actions: c_int,
    ios: *const std.os.linux.termios,
) callconv(.c) c_int {
    switch (os.errno(std.os.linux.tcsetattr(fd, @as(std.os.linux.TCSA, @enumFromInt(optional_actions)), ios))) {
        .SUCCESS => return 0,
        else => |errno| {
            c.errno = @intFromEnum(errno);
            return -1;
        },
    }
}

// --------------------------------------------------------------------------------
// strings
// --------------------------------------------------------------------------------
export fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    trace.log("strcasecmp {f} {f}", .{ trace.fmtStr(a), trace.fmtStr(b) });
    var i: usize = 0;
    while (true) : (i += 1) {
        const a_ch = std.ascii.toLower(a[i]);
        const b_ch = std.ascii.toLower(b[i]);
        if (a_ch != b_ch or a_ch == 0) {
            return @as(c_int, @intCast(a_ch)) -| @as(c_int, @intCast(b_ch));
        }
    }
}

// --------------------------------------------------------------------------------
// sys/ioctl
// --------------------------------------------------------------------------------
fn _ioctlArgPtr(fd: c_int, request: c_ulong, arg_ptr: *anyopaque) callconv(.c) c_int {
    trace.log("ioctl fd={} request=0x{x} arg={*}", .{ fd, request, arg_ptr });
    const rc = std.os.linux.ioctl(fd, @as(u32, @intCast(request)), @intFromPtr(arg_ptr));
    switch (os.errno(rc)) {
        .SUCCESS => return @as(c_int, @intCast(rc)),
        else => |errno| {
            c.errno = @intFromEnum(errno);
            return -1;
        },
    }
}

comptime {
    exportInternalSymbol(&_ioctlArgPtr, "_ioctlArgPtr");
}

// --------------------------------------------------------------------------------
// sys/select
// --------------------------------------------------------------------------------
export fn select(
    nfds: c_int,
    readfds: ?*c.fd_set,
    writefds: ?*c.fd_set,
    errorfds: ?*c.fd_set,
    timeout: ?*c.timespec,
) c_int {
    _ = nfds;
    _ = readfds;
    _ = writefds;
    _ = errorfds;
    _ = timeout;
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

// --------------------------------------------------------------------------------
// Windows
// --------------------------------------------------------------------------------
comptime {
    if (builtin.os.tag == .windows) {
        @export(&fileno, .{ .name = "_fileno" });
        @export(&isatty, .{ .name = "_isatty" });
        @export(&popen, .{ .name = "_popen" });
        @export(&pclose, .{ .name = "_pclose" });
    }
}
