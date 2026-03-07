const builtin = @import("builtin");
const std = @import("std");
const os = std.posix;
const winfd = @import("winfd.zig");
const winproc = @import("winproc.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
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
    extern fn __zwindows_sigaction(
        sig: c_int,
        act: ?*const c.struct_sigaction,
        oact: ?*c.struct_sigaction,
    ) callconv(.c) c_int;
    extern fn __zwindows_raise_signal(sig: c_int) callconv(.c) c_int;
};

extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

const trace = @import("trace.zig");

const winapi = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn CreateFileA(
        lpFileName: ?[*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?std.os.windows.HANDLE,
    ) callconv(.winapi) ?std.os.windows.HANDLE;
    pub extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetFileAttributesA(lpFileName: ?[*:0]const u8) callconv(.winapi) u32;
    pub extern "kernel32" fn SetFileAttributesA(lpFileName: ?[*:0]const u8, dwFileAttributes: u32) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetFileType(hFile: std.os.windows.HANDLE) callconv(.winapi) u32;
    pub extern "kernel32" fn GetFileInformationByHandle(
        hFile: std.os.windows.HANDLE,
        lpFileInformation: *std.os.windows.BY_HANDLE_FILE_INFORMATION,
    ) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;
    pub extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: std.os.windows.HANDLE,
        lpBuffer: ?*anyopaque,
        nBufferSize: u32,
        lpBytesRead: ?*u32,
        lpTotalBytesAvail: ?*u32,
        lpBytesLeftThisMessage: ?*u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

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
    extern "c" fn __error() *c_int;
    extern "c" fn @"open$NOCANCEL"(path: [*:0]const u8, oflag: c_int, ...) c_int;
} else struct {};

const darwin_syscall = if (builtin.os.tag.isDarwin()) struct {
    // Stable BSD syscall numbers used by Darwin's syscall(2) ABI.
    const read: c_long = 3;
    const write: c_long = 4;
    const open: c_long = 5;
    const unlink: c_long = 10;
    const chmod: c_long = 15;
    const access: c_long = 33;
    const sigaction: c_long = 46;
    const ioctl: c_long = 54;
    const setitimer: c_long = 83;
    const getitimer: c_long = 86;
    const select: c_long = 93;
    const gettimeofday: c_long = 116;
    const utimes: c_long = 138;
    const futimes: c_long = 139;
    const rename: c_long = 128;
    const pselect: c_long = 394;
} else struct {};

fn windowsStdHandleFromFd(fd: c_int) ?std.os.windows.HANDLE {
    return winfd.handleFromFd(fd);
}

// C ABI globals: `extern char *optarg; extern int opterr, optind, optopt;`
export var optarg: [*c]u8 = null;
export var opterr: c_int = 1;
export var optind: c_int = 1;
export var optopt: c_int = 0;
var optchar_index: c_int = 1;
var fallback_umask: c.mode_t = 0o022;
var fallback_umask_mutex: std.Thread.Mutex = .{};

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
    if (comptime builtin.os.tag == .windows) {
        return winproc.waitProcessStatus(@ptrFromInt(pid));
    }
    if (comptime builtin.os.tag == .wasi) {
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

fn populateLinuxExecEnviron(buf: []u8, ptrs: [*:null]?[*:0]u8, ptr_cap: usize) bool {
    if (comptime builtin.os.tag != .linux) return false;
    var file = std.fs.openFileAbsolute("/proc/self/environ", .{}) catch return false;
    defer file.close();
    const len = file.readAll(buf) catch return false;

    var count: usize = 0;
    var i: usize = 0;
    while (i < len) {
        if (count + 1 >= ptr_cap) return false;
        const begin = i;
        while (i < len and buf[i] != 0) : (i += 1) {}
        if (i == len) {
            if (len == buf.len) return false;
            buf[i] = 0;
        }
        ptrs[count] = @as([*:0]u8, @ptrCast(buf.ptr + begin));
        count += 1;
        i += 1;
    }
    ptrs[count] = null;
    return true;
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
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(isize, @intCast(rc));
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
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(isize, @intCast(rc));
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

fn translateDarwinOpenFlags(oflag: c_int) c_int {
    if (comptime !builtin.os.tag.isDarwin()) return oflag;

    var flags: std.c.O = .{};
    switch (oflag & 0x3) {
        c.O_RDONLY => flags.ACCMODE = .RDONLY,
        c.O_WRONLY => flags.ACCMODE = .WRONLY,
        c.O_RDWR => flags.ACCMODE = .RDWR,
        else => {
            c.errno = c.EINVAL;
            return -1;
        },
    }
    if ((oflag & c.O_APPEND) != 0) flags.APPEND = true;
    if ((oflag & c.O_CREAT) != 0) flags.CREAT = true;
    if ((oflag & c.O_EXCL) != 0) flags.EXCL = true;
    if ((oflag & c.O_TRUNC) != 0) flags.TRUNC = true;
    if ((oflag & c.O_NONBLOCK) != 0) flags.NONBLOCK = true;
    if ((oflag & c.O_CLOEXEC) != 0) flags.CLOEXEC = true;
    return @as(c_int, @bitCast(@as(u32, @bitCast(flags))));
}

fn zopenRaw(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int {
    if (builtin.os.tag.isDarwin()) {
        const darwin_flags = translateDarwinOpenFlags(oflag);
        if (darwin_flags == -1) return -1;
        const rc = darwin.@"open$NOCANCEL"(path, darwin_flags, mode);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return rc;
    }
    if (builtin.os.tag == .windows) {
        const accmode = oflag & 0x3;
        var desired_access: u32 = switch (accmode) {
            c.O_RDONLY => std.os.windows.GENERIC_READ,
            c.O_WRONLY => std.os.windows.GENERIC_WRITE,
            c.O_RDWR => std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            else => {
                c.errno = c.EINVAL;
                return -1;
            },
        };
        if ((oflag & c.O_APPEND) != 0) desired_access |= std.os.windows.FILE_APPEND_DATA;

        const creation_disposition: u32 = blk: {
            const creat = (oflag & c.O_CREAT) != 0;
            const excl = (oflag & c.O_EXCL) != 0;
            const trunc = (oflag & c.O_TRUNC) != 0;
            if (creat and excl) break :blk std.os.windows.CREATE_NEW;
            if (creat and trunc) break :blk std.os.windows.CREATE_ALWAYS;
            if (creat) break :blk std.os.windows.OPEN_ALWAYS;
            if (trunc) break :blk std.os.windows.TRUNCATE_EXISTING;
            break :blk std.os.windows.OPEN_EXISTING;
        };

        const attributes: u32 = if ((oflag & c.O_CREAT) != 0 and (mode & 0o222) == 0)
            std.os.windows.FILE_ATTRIBUTE_READONLY
        else
            std.os.windows.FILE_ATTRIBUTE_NORMAL;

        const handle = winapi.CreateFileA(
            path,
            desired_access,
            std.os.windows.FILE_SHARE_DELETE |
                std.os.windows.FILE_SHARE_READ |
                std.os.windows.FILE_SHARE_WRITE,
            null,
            creation_disposition,
            attributes,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }

        return winfd.allocHandle(handle.?) catch {
            _ = winapi.CloseHandle(handle.?);
            c.errno = errnoConst("EMFILE", c.ENOMEM);
            return -1;
        };
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
        const fd = if (builtin.os.tag == .windows)
            zopenRaw(template, flags | c.O_RDWR | c.O_CREAT | c.O_EXCL, 0o600)
        else blk: {
            const extra_flags: u32 = @as(u32, @intCast(flags));
            const required_flags = os.O{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .EXCL = true,
            };
            const merged_flags: os.O = @bitCast(@as(u32, @bitCast(required_flags)) | extra_flags);
            break :blk zopenRaw(
                template,
                @as(c_int, @bitCast(@as(u32, @bitCast(merged_flags)))),
                0o600,
            );
        };
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
        return winfd.fdFromHandle(stream.fd.?) orelse blk: {
            c.errno = errnoConst("EBADF", c.EINVAL);
            break :blk -1;
        };
    }
    return stream.fd;
}

export fn popen(command: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    trace.log("popen '{f}' mode='{s}'", .{ trace.fmtStr(command), mode });
    if (builtin.os.tag == .wasi) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }

    const mode_ch = mode[0];
    if (mode_ch != 'r' and mode_ch != 'w') {
        c.errno = c.EINVAL;
        return null;
    }

    if (builtin.os.tag == .windows) {
        var security = std.mem.zeroes(std.os.windows.SECURITY_ATTRIBUTES);
        security.nLength = @sizeOf(std.os.windows.SECURITY_ATTRIBUTES);
        security.bInheritHandle = 1;

        var read_handle: std.os.windows.HANDLE = undefined;
        var write_handle: std.os.windows.HANDLE = undefined;
        std.os.windows.CreatePipe(&read_handle, &write_handle, &security) catch {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return null;
        };

        const parent_handle = if (mode_ch == 'r') read_handle else write_handle;
        const child_handle = if (mode_ch == 'r') write_handle else read_handle;
        std.os.windows.SetHandleInformation(parent_handle, std.os.windows.HANDLE_FLAG_INHERIT, 0) catch {
            _ = winapi.CloseHandle(read_handle);
            _ = winapi.CloseHandle(write_handle);
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return null;
        };

        var spawn_errno: c_int = 0;
        const process_handle = if (mode_ch == 'r')
            winproc.spawnShell(command, null, child_handle, child_handle, true, &spawn_errno)
        else
            winproc.spawnShell(command, child_handle, null, null, true, &spawn_errno);
        if (process_handle == null) {
            _ = winapi.CloseHandle(read_handle);
            _ = winapi.CloseHandle(write_handle);
            c.errno = spawn_errno;
            return null;
        }
        _ = winapi.CloseHandle(child_handle);

        const parent_fd = winfd.allocHandle(parent_handle) catch {
            _ = winapi.CloseHandle(parent_handle);
            _ = winapi.CloseHandle(process_handle.?);
            c.errno = errnoConst("EMFILE", c.ENOMEM);
            return null;
        };

        const stream = fdopen(parent_fd, mode) orelse {
            const saved_errno = c.errno;
            _ = winfd.closeFd(parent_fd);
            _ = winapi.CloseHandle(process_handle.?);
            c.errno = saved_errno;
            return null;
        };
        if (!registerPopenStream(stream, @intFromPtr(process_handle.?))) {
            c.errno = errnoConst("EMFILE", c.ENOMEM);
            _ = c.fclose(stream);
            _ = winapi.CloseHandle(process_handle.?);
            return null;
        }
        return stream;
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
        if (builtin.os.tag == .linux) {
            var env_buf: [32768]u8 = undefined;
            var env_ptrs = [_:null]?[*:0]u8{null} ** 1024;
            if (populateLinuxExecEnviron(&env_buf, &env_ptrs, env_ptrs.len)) {
                _ = os.system.execve(shell_path, &argv, @ptrCast(&env_ptrs));
            }
        } else if (builtin.os.tag.isDarwin()) {
            _ = os.system.execve(shell_path, &argv, @ptrCast(_NSGetEnviron().*));
        }
        const empty_envp = [_:null]?[*:0]const u8{null};
        _ = os.system.execve(shell_path, &argv, @ptrCast(&empty_envp));
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
        const handle = winfd.handleFromFd(fd) orelse {
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
    @export(&close, .{ .name = "close" });
}
fn close(fd: c_int) callconv(.c) c_int {
    trace.log("close {}", .{fd});
    if (builtin.os.tag == .windows) {
        const close_errno = winfd.closeFd(fd);
        if (close_errno == 0) return 0;
        c.errno = close_errno;
        return -1;
    }
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
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.access, path, amode);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
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
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.unlink, path);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag == .windows) {
        std.posix.unlinkZ(path) catch |err| {
            if (err == error.AccessDenied) {
                const attrs = winapi.GetFileAttributesA(path);
                if (attrs != std.os.windows.INVALID_FILE_ATTRIBUTES and
                    (attrs & std.os.windows.FILE_ATTRIBUTE_READONLY) != 0)
                {
                    if (winapi.SetFileAttributesA(path, attrs & ~@as(u32, std.os.windows.FILE_ATTRIBUTE_READONLY)) != 0) {
                        std.posix.unlinkZ(path) catch |retry_err| {
                            c.errno = switch (retry_err) {
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
                }
            }
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
    if (builtin.os.tag.isDarwin()) {
        if (fd < 0) {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return 0;
        }
        return 0;
    }

    var size: c.winsize = undefined;
    if (_ioctlArgPtr(fd, c.TIOCGWINSZ, &size) == 0) return 1;
    if (c.errno == errnoConst("EBADF", c.EINVAL)) {
        c.errno = errnoConst("ENOTTY", c.EINVAL);
        return 0;
    }
    return 0;
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

const LinuxTimeval = extern struct {
    tv_sec: isize,
    tv_usec: isize,
};

const LinuxItimerval = extern struct {
    it_interval: LinuxTimeval,
    it_value: LinuxTimeval,
};

fn cTimevalToLinux(tv: c.timeval) LinuxTimeval {
    return .{
        .tv_sec = @as(isize, @intCast(tv.tv_sec)),
        .tv_usec = @as(isize, @intCast(tv.tv_usec)),
    };
}

fn linuxTimevalToC(tv: LinuxTimeval) c.timeval {
    var out: c.timeval = undefined;
    out.tv_sec = @as(@TypeOf(out.tv_sec), @intCast(tv.tv_sec));
    out.tv_usec = @as(@TypeOf(out.tv_usec), @intCast(tv.tv_usec));
    return out;
}

fn windowsFileTimeToUnix100ns(ft: std.os.windows.FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

fn windowsFileTimeToUnixSec(ft: std.os.windows.FILETIME) i64 {
    const ticks_100ns = windowsFileTimeToUnix100ns(ft);
    const unix_epoch_100ns: u64 = 11644473600 * 10_000_000;
    const unix_100ns = if (ticks_100ns > unix_epoch_100ns) ticks_100ns - unix_epoch_100ns else 0;
    return @as(i64, @intCast(unix_100ns / 10_000_000));
}

fn currentWindowsUnixTime() struct { sec: i64, usec: i64, nsec: i64 } {
    var ft: std.os.windows.FILETIME = undefined;
    winapi.GetSystemTimeAsFileTime(&ft);
    const ticks_100ns = windowsFileTimeToUnix100ns(ft);
    const unix_epoch_100ns: u64 = 11644473600 * 10_000_000;
    const unix_100ns = if (ticks_100ns > unix_epoch_100ns) ticks_100ns - unix_epoch_100ns else 0;
    const sec = unix_100ns / 10_000_000;
    const rem_100ns = unix_100ns % 10_000_000;
    return .{
        .sec = @as(i64, @intCast(sec)),
        .usec = @as(i64, @intCast(rem_100ns / 10)),
        .nsec = @as(i64, @intCast(rem_100ns * 100)),
    };
}

fn cTimevalIsValid(tv: c.timeval) bool {
    return tv.tv_sec >= 0 and tv.tv_usec >= 0 and tv.tv_usec < std.time.us_per_s;
}

fn cTimevalToNs(tv: c.timeval) ?u64 {
    if (!cTimevalIsValid(tv)) return null;
    const sec_ns = std.math.mul(u64, @as(u64, @intCast(tv.tv_sec)), std.time.ns_per_s) catch return null;
    const usec_ns = std.math.mul(u64, @as(u64, @intCast(tv.tv_usec)), std.time.ns_per_us) catch return null;
    return std.math.add(u64, sec_ns, usec_ns) catch null;
}

fn nsToCTimeval(ns: u64) c.timeval {
    return .{
        .tv_sec = @as(@TypeOf(@as(c.timeval, undefined).tv_sec), @intCast(ns / std.time.ns_per_s)),
        .tv_usec = @as(@TypeOf(@as(c.timeval, undefined).tv_usec), @intCast((ns % std.time.ns_per_s) / std.time.ns_per_us)),
    };
}

fn cTimespecIsValid(ts: c.timespec) bool {
    return ts.tv_sec >= 0 and ts.tv_nsec >= 0 and ts.tv_nsec < std.time.ns_per_s;
}

fn cTimespecToTimeval(ts: c.timespec) ?c.timeval {
    if (!cTimespecIsValid(ts)) return null;
    return .{
        .tv_sec = @as(@TypeOf(@as(c.timeval, undefined).tv_sec), @intCast(ts.tv_sec)),
        .tv_usec = @as(@TypeOf(@as(c.timeval, undefined).tv_usec), @intCast(@divFloor(ts.tv_nsec, std.time.ns_per_us))),
    };
}

fn windowsMonotonicNs() u64 {
    const now = std.time.Instant.now() catch return @as(u64, @intCast(@max(@as(i128, 0), std.time.nanoTimestamp())));
    return now.since(now) + @as(u64, @intCast(@max(@as(i128, 0), std.time.nanoTimestamp())));
}

fn windowsTimevalToFileTime(tv: c.timeval) ?std.os.windows.FILETIME {
    if (!cTimevalIsValid(tv)) return null;
    const sec_100ns = std.math.mul(u64, @as(u64, @intCast(tv.tv_sec)), 10_000_000) catch return null;
    const usec_100ns = std.math.mul(u64, @as(u64, @intCast(tv.tv_usec)), 10) catch return null;
    const unix_100ns = std.math.add(u64, sec_100ns, usec_100ns) catch return null;
    const file_100ns = std.math.add(u64, unix_100ns, 11644473600 * 10_000_000) catch return null;
    return .{
        .dwLowDateTime = @as(u32, @truncate(file_100ns)),
        .dwHighDateTime = @as(u32, @truncate(file_100ns >> 32)),
    };
}

const WindowsItimerState = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    thread_started: bool = false,
    armed: bool = false,
    deadline_ns: u64 = 0,
    interval_ns: u64 = 0,
};

var windows_itimer: WindowsItimerState = .{};

fn windowsCurrentItimerLocked() c.itimerval {
    var value = std.mem.zeroes(c.itimerval);
    if (!windows_itimer.armed) return value;
    const now_ns = @as(u64, @intCast(@max(@as(i128, 0), std.time.nanoTimestamp())));
    const remaining_ns = if (windows_itimer.deadline_ns > now_ns) windows_itimer.deadline_ns - now_ns else 0;
    value.it_value = nsToCTimeval(remaining_ns);
    value.it_interval = nsToCTimeval(windows_itimer.interval_ns);
    return value;
}

fn windowsItimerThread() void {
    windows_itimer.mutex.lock();
    defer windows_itimer.mutex.unlock();

    while (true) {
        while (!windows_itimer.armed) {
            windows_itimer.cond.wait(&windows_itimer.mutex);
        }

        const now_ns = @as(u64, @intCast(@max(@as(i128, 0), std.time.nanoTimestamp())));
        if (windows_itimer.deadline_ns > now_ns) {
            const wait_ns = windows_itimer.deadline_ns - now_ns;
            windows_itimer.cond.timedWait(&windows_itimer.mutex, wait_ns) catch {};
            continue;
        }

        const interval_ns = windows_itimer.interval_ns;
        if (interval_ns == 0) {
            windows_itimer.armed = false;
        } else {
            windows_itimer.deadline_ns = now_ns + interval_ns;
        }

        windows_itimer.mutex.unlock();
        _ = cstd.__zwindows_raise_signal(c.SIGALRM);
        windows_itimer.mutex.lock();
    }
}

fn ensureWindowsItimerThread() c_int {
    windows_itimer.mutex.lock();
    defer windows_itimer.mutex.unlock();
    if (windows_itimer.thread_started) return 0;
    const thread = std.Thread.spawn(.{}, windowsItimerThread, .{}) catch {
        c.errno = c.ENOMEM;
        return -1;
    };
    thread.detach();
    windows_itimer.thread_started = true;
    return 0;
}

fn timespecSec(ts: os.timespec) i64 {
    if (@hasField(os.timespec, "tv_sec")) return @as(i64, @intCast(ts.tv_sec));
    return @as(i64, @intCast(ts.sec));
}

fn timespecNsec(ts: os.timespec) i64 {
    if (@hasField(os.timespec, "tv_nsec")) return @as(i64, @intCast(ts.tv_nsec));
    return @as(i64, @intCast(ts.nsec));
}

fn _zclock_gettime(clk_id: c.clockid_t, parts: [*]c_longlong) callconv(.c) c_int {
    if (builtin.os.tag.isDarwin()) {
        if (clk_id == c.CLOCK_REALTIME) {
            var tv: c.timeval = undefined;
            if (gettimeofday(&tv, @as(?*anyopaque, null)) != 0) {
                return -1;
            }
            parts[0] = @as(c_longlong, @intCast(tv.tv_sec));
            parts[1] = @as(c_longlong, @intCast(tv.tv_usec * 1000));
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
            parts[0] = @as(c_longlong, @intCast(@divFloor(nanos, std.time.ns_per_s)));
            parts[1] = @as(c_longlong, @intCast(@mod(nanos, std.time.ns_per_s)));
            return 0;
        }

        c.errno = c.EINVAL;
        return -1;
    }

    if (builtin.os.tag == .windows) {
        if (clk_id == c.CLOCK_REALTIME) {
            const now = currentWindowsUnixTime();
            parts[0] = @as(c_longlong, @intCast(now.sec));
            parts[1] = @as(c_longlong, @intCast(now.nsec));
            return 0;
        }
        c.errno = c.EINVAL;
        return -1;
    }

    var ts: os.timespec = undefined;
    const posix_clk_id: os.clockid_t = @enumFromInt(@as(u32, @intCast(clk_id)));
    switch (os.errno(os.system.clock_gettime(posix_clk_id, &ts))) {
        .SUCCESS => {
            parts[0] = @as(c_longlong, @intCast(timespecSec(ts)));
            parts[1] = @as(c_longlong, @intCast(timespecNsec(ts)));
            return 0;
        },
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

comptime {
    exportInternalSymbol(&_zclock_gettime, "_zclock_gettime");
}

export fn gettimeofday(tv: *c.timeval, tz: ?*anyopaque) callconv(.c) c_int {
    trace.log("gettimeofday tv={*} tz={*}", .{ tv, tz });
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.gettimeofday, tv, tz);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag == .windows) {
        const now = currentWindowsUnixTime();
        tv.tv_sec = @as(@TypeOf(tv.tv_sec), @intCast(now.sec));
        tv.tv_usec = @as(@TypeOf(tv.tv_usec), @intCast(now.usec));
        return 0;
    }
    const ns = std.time.nanoTimestamp();
    tv.tv_sec = @as(@TypeOf(tv.tv_sec), @intCast(@divFloor(ns, std.time.ns_per_s)));
    tv.tv_usec = @as(@TypeOf(tv.tv_usec), @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us)));
    return 0;
}

export fn getitimer(which: c_int, value: *c.itimerval) callconv(.c) c_int {
    trace.log("getitimer which={}", .{which});
    if (builtin.os.tag == .windows) {
        if (which != c.ITIMER_REAL) {
            c.errno = c.EINVAL;
            return -1;
        }
        windows_itimer.mutex.lock();
        value.* = windowsCurrentItimerLocked();
        windows_itimer.mutex.unlock();
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.getitimer, which, value);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.syscall2(
            .getitimer,
            @as(usize, @bitCast(@as(isize, which))),
            @intFromPtr(value),
        );
        switch (os.errno(rc)) {
            .SUCCESS => return 0,
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

export fn setitimer(which: c_int, value: *const c.itimerval, avalue: *c.itimerval) callconv(.c) c_int {
    trace.log("setitimer which={}", .{which});
    if (builtin.os.tag == .windows) {
        if (which != c.ITIMER_REAL) {
            c.errno = c.EINVAL;
            return -1;
        }
        const value_ns = cTimevalToNs(value.it_value) orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const interval_ns = cTimevalToNs(value.it_interval) orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        if (value_ns != 0 and ensureWindowsItimerThread() != 0) return -1;

        windows_itimer.mutex.lock();
        avalue.* = windowsCurrentItimerLocked();
        if (value_ns == 0) {
            windows_itimer.armed = false;
            windows_itimer.deadline_ns = 0;
            windows_itimer.interval_ns = 0;
        } else {
            const now_ns = @as(u64, @intCast(@max(@as(i128, 0), std.time.nanoTimestamp())));
            windows_itimer.armed = true;
            windows_itimer.deadline_ns = now_ns + value_ns;
            windows_itimer.interval_ns = interval_ns;
        }
        windows_itimer.cond.broadcast();
        windows_itimer.mutex.unlock();
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.setitimer, which, value, avalue);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (comptime builtin.os.tag != .linux) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    var linux_new = LinuxItimerval{
        .it_interval = cTimevalToLinux(value.it_interval),
        .it_value = cTimevalToLinux(value.it_value),
    };
    var linux_old: LinuxItimerval = undefined;
    const rc = std.os.linux.syscall3(
        .setitimer,
        @as(usize, @bitCast(@as(isize, which))),
        @intFromPtr(&linux_new),
        @intFromPtr(&linux_old),
    );
    switch (os.errno(rc)) {
        .SUCCESS => {
            avalue.it_interval = linuxTimevalToC(linux_old.it_interval);
            avalue.it_value = linuxTimevalToC(linux_old.it_value);
            return 0;
        },
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

// --------------------------------------------------------------------------------
// signal
// --------------------------------------------------------------------------------
fn cHandlerToLinux(handler: @TypeOf(@as(c.struct_sigaction, undefined).sa_handler)) ?std.os.linux.Sigaction.handler_fn {
    return if (handler) |h|
        @as(?std.os.linux.Sigaction.handler_fn, @ptrFromInt(@intFromPtr(h)))
    else
        null;
}

fn cSigactionToLinux(sigaction_fn: @TypeOf(@as(c.struct_sigaction, undefined).sa_sigaction)) ?std.os.linux.Sigaction.sigaction_fn {
    return if (sigaction_fn) |f|
        @as(?std.os.linux.Sigaction.sigaction_fn, @ptrFromInt(@intFromPtr(f)))
    else
        null;
}

fn linuxHandlerToC(handler: ?std.os.linux.Sigaction.handler_fn) @TypeOf(@as(c.struct_sigaction, undefined).sa_handler) {
    return if (handler) |h|
        @as(@TypeOf(@as(c.struct_sigaction, undefined).sa_handler), @ptrFromInt(@intFromPtr(h)))
    else
        null;
}

fn linuxSigactionToC(sigaction_fn: ?std.os.linux.Sigaction.sigaction_fn) @TypeOf(@as(c.struct_sigaction, undefined).sa_sigaction) {
    return if (sigaction_fn) |f|
        @as(@TypeOf(@as(c.struct_sigaction, undefined).sa_sigaction), @ptrFromInt(@intFromPtr(f)))
    else
        null;
}

fn cSigsetToLinux(mask: c.sigset_t) std.os.linux.sigset_t {
    var out = std.os.linux.sigemptyset();
    out[0] = @as(@TypeOf(out[0]), @intCast(mask.__signals));
    return out;
}

fn linuxSigsetToC(mask: std.os.linux.sigset_t) c.sigset_t {
    return .{ .__signals = @as(c_ulong, @intCast(mask[0])) };
}

fn cSigsetToDarwin(mask: c.sigset_t) std.c.sigset_t {
    return @as(std.c.sigset_t, @truncate(mask.__signals));
}

fn darwinSigsetToC(mask: std.c.sigset_t) c.sigset_t {
    return .{ .__signals = @as(c_ulong, @intCast(mask)) };
}

export fn sigaction(sig: c_int, act: *const c.struct_sigaction, oact: *c.struct_sigaction) callconv(.c) c_int {
    trace.log("sigaction sig={}", .{sig});
    if (builtin.os.tag == .windows) {
        return cstd.__zwindows_sigaction(sig, act, oact);
    }
    if (builtin.os.tag.isDarwin()) {
        var native_act = std.mem.zeroes(std.c.Sigaction);
        native_act.mask = cSigsetToDarwin(act.sa_mask);
        native_act.flags = @as(c_uint, @bitCast(act.sa_flags));
        if ((native_act.flags & std.c.SA.SIGINFO) != 0) {
            native_act.handler.sigaction = if (act.sa_sigaction) |f|
                @as(?std.c.Sigaction.sigaction_fn, @ptrFromInt(@intFromPtr(f)))
            else
                null;
        } else {
            native_act.handler.handler = if (act.sa_handler) |h|
                @as(?std.c.Sigaction.handler_fn, @ptrFromInt(@intFromPtr(h)))
            else
                null;
        }

        var native_old = std.mem.zeroes(std.c.Sigaction);
        const rc = syscall(darwin_syscall.sigaction, sig, &native_act, &native_old);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        oact.sa_mask = darwinSigsetToC(native_old.mask);
        oact.sa_flags = @as(c_int, @bitCast(native_old.flags));
        if ((native_old.flags & std.c.SA.SIGINFO) != 0) {
            oact.sa_sigaction = if (native_old.handler.sigaction) |f|
                @as(@TypeOf(oact.sa_sigaction), @ptrFromInt(@intFromPtr(f)))
            else
                null;
            oact.sa_handler = null;
        } else {
            oact.sa_handler = if (native_old.handler.handler) |h|
                @as(@TypeOf(oact.sa_handler), @ptrFromInt(@intFromPtr(h)))
            else
                null;
            oact.sa_sigaction = null;
        }
        return 0;
    }
    if (comptime builtin.os.tag != .linux) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    if (sig <= 0 or sig >= std.os.linux.NSIG) {
        c.errno = c.EINVAL;
        return -1;
    }

    const flags_bits: c_uint = @bitCast(act.sa_flags);
    var linux_act = std.os.linux.Sigaction{
        .handler = undefined,
        .mask = cSigsetToLinux(act.sa_mask),
        .flags = @as(@TypeOf(@as(std.os.linux.Sigaction, undefined).flags), @intCast(flags_bits)),
    };
    if ((flags_bits & std.os.linux.SA.SIGINFO) != 0) {
        linux_act.handler = .{ .sigaction = cSigactionToLinux(act.sa_sigaction) };
    } else {
        linux_act.handler = .{ .handler = cHandlerToLinux(act.sa_handler) };
    }

    var linux_old: std.os.linux.Sigaction = undefined;
    const rc = std.os.linux.sigaction(@as(u8, @intCast(sig)), &linux_act, &linux_old);
    switch (os.errno(rc)) {
        .SUCCESS => {
            const old_flags_bits: c_uint = @truncate(@as(usize, @intCast(linux_old.flags)));
            oact.sa_flags = @as(c_int, @bitCast(old_flags_bits));
            oact.sa_mask = linuxSigsetToC(linux_old.mask);
            if ((old_flags_bits & std.os.linux.SA.SIGINFO) != 0) {
                oact.sa_sigaction = linuxSigactionToC(linux_old.handler.sigaction);
                oact.sa_handler = null;
            } else {
                oact.sa_handler = linuxHandlerToC(linux_old.handler.handler);
                oact.sa_sigaction = null;
            }
            return 0;
        },
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

// --------------------------------------------------------------------------------
// sys/stat.h
// --------------------------------------------------------------------------------
export fn stat(path: [*:0]const u8, buf: *c.struct_stat) callconv(.c) c_int {
    if (builtin.os.tag == .windows) {
        const fd = zopenRaw(path, c.O_RDONLY, 0);
        if (fd < 0) return -1;
        defer _ = close(fd);
        return fstat(fd, buf);
    }

    // `stat()` is a pathname query, not `open()+fstat()`. The shortcut happened to
    // pass under Darling, but native macOS diverged in CI and truncated the
    // `utimes` parity test because pathname lookup semantics and openability are
    // not equivalent. Keep POSIX targets on a real pathname stat so Darwin and
    // Linux both observe the same file metadata that the system libc does.
    var stat_buf: os.Stat = undefined;
    const fstatat_sym = if (@hasDecl(os.system, "fstatat64")) os.system.fstatat64 else os.system.fstatat;
    switch (os.errno(fstatat_sym(os.AT.FDCWD, path, &stat_buf, 0))) {
        .SUCCESS => {
            copyPosixStatToC(buf, stat_buf);
            return 0;
        },
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

export fn chmod(path: [*:0]const u8, mode: c.mode_t) callconv(.c) c_int {
    trace.log("chmod '{s}' mode=0x{x}", .{ path, mode });
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.chmod, path, @as(c_uint, @intCast(mode)));
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag == .windows) {
        const attrs = winapi.GetFileAttributesA(path);
        if (attrs == std.os.windows.INVALID_FILE_ATTRIBUTES) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }

        const writable = (@as(c_uint, @intCast(mode)) & 0o222) != 0;
        var new_attrs = attrs;
        if (writable) {
            new_attrs &= ~@as(u32, std.os.windows.FILE_ATTRIBUTE_READONLY);
        } else {
            new_attrs |= std.os.windows.FILE_ATTRIBUTE_READONLY;
        }
        if (winapi.SetFileAttributesA(path, new_attrs) == 0) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }
        return 0;
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

fn copyPosixStatToC(buf: *c.struct_stat, stat_buf: os.Stat) void {
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
}

export fn fstat(fd: c_int, buf: *c.struct_stat) c_int {
    if (builtin.os.tag == .windows) {
        const handle = winfd.handleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return -1;
        };
        buf.* = std.mem.zeroes(c.struct_stat);

        const file_type = winapi.GetFileType(handle);
        if (file_type == 0) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }

        if (file_type == 0x0002 or file_type == 0x0003) {
            buf.st_nlink = 1;
            buf.st_mode = c.S_IRUSR | c.S_IWUSR;
            return 0;
        }

        var info: std.os.windows.BY_HANDLE_FILE_INFORMATION = undefined;
        if (winapi.GetFileInformationByHandle(handle, &info) == 0) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }
        const readonly = (info.dwFileAttributes & std.os.windows.FILE_ATTRIBUTE_READONLY) != 0;
        const size: u64 = (@as(u64, info.nFileSizeHigh) << 32) | @as(u64, info.nFileSizeLow);
        const inode: u64 = (@as(u64, info.nFileIndexHigh) << 32) | @as(u64, info.nFileIndexLow);

        buf.st_dev = @as(@TypeOf(buf.st_dev), @intCast(info.dwVolumeSerialNumber));
        buf.st_ino = @as(@TypeOf(buf.st_ino), @intCast(inode));
        const mode_bits: c_int = c.S_IRUSR | (if (readonly) @as(c_int, 0) else c.S_IWUSR);
        buf.st_mode = @as(@TypeOf(buf.st_mode), @intCast(mode_bits));
        buf.st_nlink = @as(@TypeOf(buf.st_nlink), @intCast(if (info.nNumberOfLinks == 0) 1 else info.nNumberOfLinks));
        buf.st_size = @as(@TypeOf(buf.st_size), @intCast(size));
        buf.st_atime = @as(@TypeOf(buf.st_atime), @intCast(windowsFileTimeToUnixSec(info.ftLastAccessTime)));
        buf.st_mtime = @as(@TypeOf(buf.st_mtime), @intCast(windowsFileTimeToUnixSec(info.ftLastWriteTime)));
        buf.st_ctime = @as(@TypeOf(buf.st_ctime), @intCast(windowsFileTimeToUnixSec(info.ftCreationTime)));
        return 0;
    }
    var stat_buf: os.Stat = undefined;
    switch (os.errno(os.system.fstat(fd, &stat_buf))) {
        .SUCCESS => {},
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }

    copyPosixStatToC(buf, stat_buf);
    return 0;
}

export fn umask(mode: c.mode_t) callconv(.c) c.mode_t {
    trace.log("umask 0x{x}", .{mode});
    if (builtin.os.tag == .linux) {
        const old_mode = std.os.linux.syscall1(.umask, @as(usize, @intCast(mode)));
        return @as(c.mode_t, @intCast(old_mode));
    }

    fallback_umask_mutex.lock();
    defer fallback_umask_mutex.unlock();
    const old = fallback_umask;
    fallback_umask = mode & 0o777;
    return old;
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
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.ioctl, fd, request, arg_ptr);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(c_int, @intCast(rc));
    }
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
const FdSetWord = @TypeOf(@as(c.fd_set, undefined).fds_bits[0]);
const fd_set_word_bits = @bitSizeOf(FdSetWord);
const fd_set_capacity = @typeInfo(@TypeOf(@as(c.fd_set, undefined).fds_bits)).array.len * fd_set_word_bits;
const windows_file_type_disk: u32 = 0x0001;
const windows_file_type_char: u32 = 0x0002;
const windows_file_type_pipe: u32 = 0x0003;

fn fdSetParts(fd: c_int) ?struct { word: usize, mask: FdSetWord } {
    if (fd < 0 or fd >= fd_set_capacity) return null;
    const word = @as(usize, @intCast(fd)) / fd_set_word_bits;
    const bit = @as(std.math.Log2Int(FdSetWord), @intCast(@as(usize, @intCast(fd)) % fd_set_word_bits));
    return .{ .word = word, .mask = @as(FdSetWord, 1) << bit };
}

export fn FD_ZERO(fdset: *c.fd_set) callconv(.c) void {
    @memset(fdset.fds_bits[0..], 0);
}

export fn FD_SET(fd: c_int, fdset: *c.fd_set) callconv(.c) void {
    const parts = fdSetParts(fd) orelse return;
    fdset.fds_bits[parts.word] |= parts.mask;
}

export fn FD_CLR(fd: c_int, fdset: *c.fd_set) callconv(.c) void {
    const parts = fdSetParts(fd) orelse return;
    fdset.fds_bits[parts.word] &= ~parts.mask;
}

export fn FD_ISSET(fd: c_int, fdset: *c.fd_set) callconv(.c) c_int {
    const parts = fdSetParts(fd) orelse return 0;
    return @intFromBool((fdset.fds_bits[parts.word] & parts.mask) != 0);
}

fn windowsHandleReadable(handle: std.os.windows.HANDLE) ?bool {
    const file_type = winapi.GetFileType(handle);
    switch (file_type) {
        windows_file_type_disk,
        windows_file_type_char,
        => return true,
        windows_file_type_pipe => {
            var available: u32 = 0;
            if (winapi.PeekNamedPipe(handle, null, 0, null, &available, null) != 0) {
                return available != 0;
            }
            const win_err = std.os.windows.kernel32.GetLastError();
            if (win_err == .BROKEN_PIPE) return true;
            c.errno = winfd.errnoFromWin32(win_err);
            return null;
        },
        else => {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return null;
        },
    }
}

fn windowsHandleWritable(handle: std.os.windows.HANDLE) ?bool {
    const file_type = winapi.GetFileType(handle);
    switch (file_type) {
        windows_file_type_disk,
        windows_file_type_char,
        windows_file_type_pipe,
        => return true,
        else => {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return null;
        },
    }
}

fn windowsSelectScanSet(comptime mode: enum { read, write, err }, nfds: c_int, fdset: *c.fd_set) ?c_int {
    var ready_count: c_int = 0;
    var fd: c_int = 0;
    while (fd < nfds) : (fd += 1) {
        if (FD_ISSET(fd, fdset) == 0) continue;
        const handle = winfd.handleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return null;
        };
        const is_ready = switch (mode) {
            .read => windowsHandleReadable(handle),
            .write => windowsHandleWritable(handle),
            .err => false,
        };
        if (is_ready == null) return null;
        if (is_ready.?) {
            ready_count += 1;
        } else {
            FD_CLR(fd, fdset);
        }
    }
    return ready_count;
}

export fn select(
    nfds: c_int,
    readfds: ?*c.fd_set,
    writefds: ?*c.fd_set,
    errorfds: ?*c.fd_set,
    timeout: ?*c.timeval,
) c_int {
    if (nfds < 0) {
        c.errno = c.EINVAL;
        return -1;
    }
    if (nfds > fd_set_capacity) {
        c.errno = c.EINVAL;
        return -1;
    }
    if (builtin.os.tag == .windows) {
        var read_template: c.fd_set = undefined;
        var write_template: c.fd_set = undefined;
        var error_template: c.fd_set = undefined;
        if (readfds) |rf| read_template = rf.*;
        if (writefds) |wf| write_template = wf.*;
        if (errorfds) |ef| error_template = ef.*;

        const timeout_ns: ?u64 = if (timeout) |to| blk: {
            if (to.tv_sec < 0 or to.tv_usec < 0 or to.tv_usec >= 1000000) {
                c.errno = c.EINVAL;
                return -1;
            }
            const sec_ns = std.math.mul(u64, @as(u64, @intCast(to.tv_sec)), std.time.ns_per_s) catch {
                c.errno = c.EINVAL;
                return -1;
            };
            const usec_ns = std.math.mul(u64, @as(u64, @intCast(to.tv_usec)), std.time.ns_per_us) catch {
                c.errno = c.EINVAL;
                return -1;
            };
            break :blk std.math.add(u64, sec_ns, usec_ns) catch {
                c.errno = c.EINVAL;
                return -1;
            };
        } else null;
        const start_ns = if (timeout_ns != null) std.time.nanoTimestamp() else 0;

        while (true) {
            if (readfds) |rf| rf.* = read_template;
            if (writefds) |wf| wf.* = write_template;
            if (errorfds) |ef| ef.* = error_template;

            var ready_count: c_int = 0;
            if (readfds) |rf| {
                ready_count += windowsSelectScanSet(.read, nfds, rf) orelse return -1;
            }
            if (writefds) |wf| {
                ready_count += windowsSelectScanSet(.write, nfds, wf) orelse return -1;
            }
            if (errorfds) |ef| {
                FD_ZERO(ef);
            }
            if (ready_count != 0) {
                if (timeout) |to| {
                    to.tv_sec = 0;
                    to.tv_usec = 0;
                }
                return ready_count;
            }

            if (timeout_ns) |limit_ns| {
                const elapsed_ns = @as(u64, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
                if (elapsed_ns >= limit_ns) {
                    if (readfds) |rf| FD_ZERO(rf);
                    if (writefds) |wf| FD_ZERO(wf);
                    if (errorfds) |ef| FD_ZERO(ef);
                    if (timeout) |to| {
                        to.tv_sec = 0;
                        to.tv_usec = 0;
                    }
                    return 0;
                }
                const remaining_ns = limit_ns - elapsed_ns;
                std.Thread.sleep(@min(remaining_ns, std.time.ns_per_ms));
            } else {
                std.Thread.sleep(std.time.ns_per_ms);
            }
        }
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(
            darwin_syscall.select,
            nfds,
            readfds,
            writefds,
            errorfds,
            timeout,
        );
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(c_int, @intCast(rc));
    }
    if (builtin.os.tag == .linux) {
        var linux_timeout: LinuxTimeval = undefined;
        const timeout_ptr: usize = if (timeout) |to| blk: {
            linux_timeout = cTimevalToLinux(to.*);
            break :blk @intFromPtr(&linux_timeout);
        } else 0;
        const rc = std.os.linux.syscall5(
            .select,
            @as(usize, @bitCast(@as(isize, nfds))),
            @intFromPtr(readfds),
            @intFromPtr(writefds),
            @intFromPtr(errorfds),
            timeout_ptr,
        );
        switch (os.errno(rc)) {
            .SUCCESS => {
                if (timeout) |to| to.* = linuxTimevalToC(linux_timeout);
                return @as(c_int, @intCast(rc));
            },
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }

    // Portable fallback for "sleep with timeout" mode only.
    if (nfds == 0 and readfds == null and writefds == null and errorfds == null) {
        if (timeout) |to| {
            if (to.tv_sec < 0 or to.tv_usec < 0 or to.tv_usec >= 1000000) {
                c.errno = c.EINVAL;
                return -1;
            }
            const sec_ns = std.math.mul(u64, @as(u64, @intCast(to.tv_sec)), std.time.ns_per_s) catch {
                c.errno = c.EINVAL;
                return -1;
            };
            const usec_ns = std.math.mul(u64, @as(u64, @intCast(to.tv_usec)), std.time.ns_per_us) catch {
                c.errno = c.EINVAL;
                return -1;
            };
            const total_ns = std.math.add(u64, sec_ns, usec_ns) catch {
                c.errno = c.EINVAL;
                return -1;
            };
            if (total_ns != 0) std.Thread.sleep(total_ns);
            to.tv_sec = 0;
            to.tv_usec = 0;
            return 0;
        } else {
            // No timeout and no fds would block forever; keep behavior explicit.
            c.errno = errnoConst("ENOSYS", c.EINVAL);
            return -1;
        }
    }
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

export fn pselect(
    nfds: c_int,
    readfds: ?*c.fd_set,
    writefds: ?*c.fd_set,
    errorfds: ?*c.fd_set,
    timeout: ?*const c.timespec,
    sigmask: ?*const c.sigset_t,
) c_int {
    if (nfds < 0) {
        c.errno = c.EINVAL;
        return -1;
    }
    if (builtin.os.tag.isDarwin()) {
        var darwin_timeout: c.timeval = undefined;
        const darwin_timeout_ptr: ?*c.timeval = if (timeout) |ts| blk: {
            darwin_timeout = cTimespecToTimeval(ts.*) orelse {
                c.errno = c.EINVAL;
                return -1;
            };
            break :blk &darwin_timeout;
        } else null;
        return select(nfds, readfds, writefds, errorfds, darwin_timeout_ptr);
    }
    if (builtin.os.tag == .linux) {
        const LinuxPselectSigmask = extern struct {
            sigmask: *const c.sigset_t,
            sigsetsize: usize,
        };
        var sigdata = LinuxPselectSigmask{ .sigmask = undefined, .sigsetsize = @sizeOf(c.sigset_t) };
        const sigdata_ptr: usize = if (sigmask) |mask| blk: {
            sigdata.sigmask = mask;
            break :blk @intFromPtr(&sigdata);
        } else 0;
        const rc = std.os.linux.syscall6(
            .pselect6,
            @as(usize, @bitCast(@as(isize, nfds))),
            @intFromPtr(readfds),
            @intFromPtr(writefds),
            @intFromPtr(errorfds),
            @intFromPtr(timeout),
            sigdata_ptr,
        );
        switch (os.errno(rc)) {
            .SUCCESS => return @as(c_int, @intCast(rc)),
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }

    var select_timeout: c.timeval = undefined;
    const select_timeout_ptr: ?*c.timeval = if (timeout) |ts| blk: {
        select_timeout = cTimespecToTimeval(ts.*) orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        break :blk &select_timeout;
    } else null;
    return select(nfds, readfds, writefds, errorfds, select_timeout_ptr);
}

export fn utimes(filename: [*:0]const u8, times: [*c]const c.timeval) callconv(.c) c_int {
    if (times) |tv| {
        if (!cTimevalIsValid(tv[0]) or !cTimevalIsValid(tv[1])) {
            c.errno = c.EINVAL;
            return -1;
        }
    }
    if (builtin.os.tag == .windows) {
        const handle = winapi.CreateFileA(
            filename,
            std.os.windows.FILE_WRITE_ATTRIBUTES,
            std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
            null,
            std.os.windows.OPEN_EXISTING,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }
        defer _ = winapi.CloseHandle(handle.?);

        var access_time: std.os.windows.FILETIME = undefined;
        var write_time: std.os.windows.FILETIME = undefined;
        var current_time: std.os.windows.FILETIME = undefined;
        const access_ptr, const write_ptr = if (times) |tv| blk: {
            access_time = windowsTimevalToFileTime(tv[0]) orelse {
                c.errno = c.EINVAL;
                return -1;
            };
            write_time = windowsTimevalToFileTime(tv[1]) orelse {
                c.errno = c.EINVAL;
                return -1;
            };
            break :blk .{ &access_time, &write_time };
        } else blk: {
            winapi.GetSystemTimeAsFileTime(&current_time);
            break :blk .{ &current_time, &current_time };
        };

        std.os.windows.SetFileTime(handle.?, null, access_ptr, write_ptr) catch {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        };
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const fd = zopenRaw(filename, c.O_RDONLY, 0);
        if (fd < 0) return -1;
        defer _ = close(fd);
        const rc = syscall(darwin_syscall.futimes, fd, times);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.syscall2(
            .utimes,
            @intFromPtr(filename),
            @intFromPtr(times),
        );
        switch (os.errno(rc)) {
            .SUCCESS => return 0,
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }
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
