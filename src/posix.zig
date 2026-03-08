const builtin = @import("builtin");
const std = @import("std");
const os = std.posix;
const winfd = @import("winfd.zig");
const winproc = @import("winproc.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("strings.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("locale.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
    @cInclude("dirent.h");
    @cInclude("termios.h");
    @cInclude("sys/time.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/select.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("dirent.h");
});

const cstd = struct {
    extern fn __zreserveFile() callconv(.c) ?*c.FILE;
    extern fn strncasecmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int;
    extern fn __zwindows_sigaction(
        sig: c_int,
        act: ?*const c.struct_sigaction,
        oact: ?*c.struct_sigaction,
    ) callconv(.c) c_int;
    extern fn __zwindows_raise_signal(sig: c_int) callconv(.c) c_int;
};

const AtomicFlag = std.atomic.Value(u32);

fn spinPause() void {
    std.Thread.yield() catch std.Thread.sleep(50 * std.time.ns_per_us);
}

const SpinLock = struct {
    state: AtomicFlag = AtomicFlag.init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            spinPause();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
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
    pub extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *u32) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?std.os.windows.HMODULE;
    pub extern "kernel32" fn GetProcAddress(hModule: ?std.os.windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn CreateHardLinkA(
        lpFileName: [*:0]const u8,
        lpExistingFileName: [*:0]const u8,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;
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
    const recvfrom: c_long = 29;
    const getpeername: c_long = 31;
    const socket: c_long = 97;
    const connect: c_long = 98;
    const recv: c_long = 102;
    const bind: c_long = 104;
    const setsockopt: c_long = 105;
    const getsockopt: c_long = 118;
    const sendto: c_long = 133;
    const shutdown: c_long = 134;
    const setitimer: c_long = 83;
    const getitimer: c_long = 86;
    const fcntl: c_long = 92;
    const select: c_long = 93;
    const gettimeofday: c_long = 116;
    const getsockname: c_long = 32;
    const rename: c_long = 128;
    const utimes: c_long = 138;
    const futimes: c_long = 139;
    // xnu's syscall table exposes openat via a stable BSD number on Darwin.
    const openat: c_long = 463;
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
var fallback_umask_mutex: SpinLock = .{};
var dirname_dot: [2:0]u8 = [_:0]u8{'.', 0};
var dirname_root: [2:0]u8 = [_:0]u8{'/', 0};

const PopenPid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) usize else os.pid_t;
const PopenEntry = struct {
    stream: ?*c.FILE = null,
    pid: PopenPid = 0,
};

const HostentState = struct {
    mutex: SpinLock = .{},
    name_buf: [256]u8 = [_]u8{0} ** 256,
    addr_buf: [4]u8 = [_]u8{0} ** 4,
    aliases: [1:null]?[*:0]u8 = .{null},
    addr_list: [2:null]?[*:0]u8 = .{ null, null },
    hostent: c.struct_hostent = .{
        .h_name = null,
        .h_aliases = null,
        .h_addrtype = c.AF_INET,
        .h_length = 4,
        .h_addr_list = null,
    },
};

var popen_entries: [c.FOPEN_MAX]PopenEntry = [_]PopenEntry{.{}} ** c.FOPEN_MAX;
var popen_mutex: SpinLock = .{};
var hostent_state: HostentState = .{};

// Keep synthetic socket fds inside our exported FD_SETSIZE so callers can use
// them with FD_SET/FD_ISSET/select on Windows just like regular descriptors.
const windows_socket_base: c_int = 512;
const windows_socket_slots = 128;
const WindowsSocket = std.os.windows.ws2_32.SOCKET;
const WindowsSelectMode = enum { read, write, err };
const WindowsSocketEntry = struct {
    used: bool = false,
    socket: WindowsSocket = std.os.windows.ws2_32.INVALID_SOCKET,
};
var windows_socket_mutex: SpinLock = .{};
var windows_socket_entries: [windows_socket_slots]WindowsSocketEntry = [_]WindowsSocketEntry{.{}} ** windows_socket_slots;
var windows_wsa_once = std.once(struct {
    fn init() void {
        std.os.windows.callWSAStartup() catch {};
    }
}.init);
const WinsockRawSocketFn = *const fn (af: i32, @"type": i32, protocol: i32) callconv(.winapi) WindowsSocket;
const WinsockRawBindFn = *const fn (s: WindowsSocket, name: *const std.os.windows.ws2_32.sockaddr, namelen: i32) callconv(.winapi) i32;
const WinsockRawConnectFn = *const fn (s: WindowsSocket, name: *const std.os.windows.ws2_32.sockaddr, namelen: i32) callconv(.winapi) i32;
const WinsockRawGetNameFn = *const fn (s: WindowsSocket, name: *std.os.windows.ws2_32.sockaddr, namelen: *i32) callconv(.winapi) i32;
const WinsockRawGetSockOptFn = *const fn (s: WindowsSocket, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;
const WinsockRawSetSockOptFn = *const fn (s: WindowsSocket, level: i32, optname: i32, optval: ?[*]const u8, optlen: i32) callconv(.winapi) i32;
const WinsockRawSendFn = *const fn (s: WindowsSocket, buf: [*]const u8, len: i32, flags: u32) callconv(.winapi) i32;
const WinsockRawSendToFn = *const fn (s: WindowsSocket, buf: [*]const u8, len: i32, flags: i32, to: ?*const std.os.windows.ws2_32.sockaddr, tolen: i32) callconv(.winapi) i32;
const WinsockRawRecvFn = *const fn (s: WindowsSocket, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
const WinsockRawRecvFromFn = *const fn (s: WindowsSocket, buf: [*]u8, len: i32, flags: i32, from: ?*std.os.windows.ws2_32.sockaddr, fromlen: ?*i32) callconv(.winapi) i32;
const WinsockRawShutdownFn = *const fn (s: WindowsSocket, how: i32) callconv(.winapi) i32;
const WinsockRawSelectFn = *const fn (
    nfds: i32,
    readfds: ?*std.os.windows.ws2_32.fd_set,
    writefds: ?*std.os.windows.ws2_32.fd_set,
    exceptfds: ?*std.os.windows.ws2_32.fd_set,
    timeout: ?*const std.os.windows.ws2_32.timeval,
) callconv(.winapi) i32;
// On Windows, calling imported Winsock functions by their plain names from the
// same image that exports libc symbols such as `socket`, `bind`, `connect`,
// `recv`, or `shutdown` can self-bind back into our own exports and recurse
// until stack overflow. Resolve those entry points through GetProcAddress so
// the Windows socket path always targets ws2_32.dll directly.
const WinsockApi = struct {
    module: ?std.os.windows.HMODULE = null,
    socket_fn: ?WinsockRawSocketFn = null,
    bind_fn: ?WinsockRawBindFn = null,
    connect_fn: ?WinsockRawConnectFn = null,
    getsockname_fn: ?WinsockRawGetNameFn = null,
    getpeername_fn: ?WinsockRawGetNameFn = null,
    getsockopt_fn: ?WinsockRawGetSockOptFn = null,
    setsockopt_fn: ?WinsockRawSetSockOptFn = null,
    send_fn: ?WinsockRawSendFn = null,
    sendto_fn: ?WinsockRawSendToFn = null,
    recv_fn: ?WinsockRawRecvFn = null,
    recvfrom_fn: ?WinsockRawRecvFromFn = null,
    shutdown_fn: ?WinsockRawShutdownFn = null,
    select_fn: ?WinsockRawSelectFn = null,
};
var windows_winsock_api: WinsockApi = .{};
var windows_winsock_api_once = std.once(struct {
    fn init() void {
        const module = winapi.LoadLibraryA("ws2_32.dll") orelse return;
        windows_winsock_api.module = module;
        windows_winsock_api.socket_fn = @ptrCast(winapi.GetProcAddress(module, "socket") orelse return);
        windows_winsock_api.bind_fn = @ptrCast(winapi.GetProcAddress(module, "bind") orelse return);
        windows_winsock_api.connect_fn = @ptrCast(winapi.GetProcAddress(module, "connect") orelse return);
        windows_winsock_api.getsockname_fn = @ptrCast(winapi.GetProcAddress(module, "getsockname") orelse return);
        windows_winsock_api.getpeername_fn = @ptrCast(winapi.GetProcAddress(module, "getpeername") orelse return);
        windows_winsock_api.getsockopt_fn = @ptrCast(winapi.GetProcAddress(module, "getsockopt") orelse return);
        windows_winsock_api.setsockopt_fn = @ptrCast(winapi.GetProcAddress(module, "setsockopt") orelse return);
        windows_winsock_api.send_fn = @ptrCast(winapi.GetProcAddress(module, "send") orelse return);
        windows_winsock_api.sendto_fn = @ptrCast(winapi.GetProcAddress(module, "sendto") orelse return);
        windows_winsock_api.recv_fn = @ptrCast(winapi.GetProcAddress(module, "recv") orelse return);
        windows_winsock_api.recvfrom_fn = @ptrCast(winapi.GetProcAddress(module, "recvfrom") orelse return);
        windows_winsock_api.shutdown_fn = @ptrCast(winapi.GetProcAddress(module, "shutdown") orelse return);
        windows_winsock_api.select_fn = @ptrCast(winapi.GetProcAddress(module, "select") orelse return);
    }
}.init);

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

fn ensureWindowsSockets() void {
    if (comptime builtin.os.tag != .windows) return;
    windows_wsa_once.call();
    windows_winsock_api_once.call();
}

fn windowsWinsockReady() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return windows_winsock_api.socket_fn != null and
        windows_winsock_api.bind_fn != null and
        windows_winsock_api.connect_fn != null and
        windows_winsock_api.getsockname_fn != null and
        windows_winsock_api.getpeername_fn != null and
        windows_winsock_api.getsockopt_fn != null and
        windows_winsock_api.setsockopt_fn != null and
        windows_winsock_api.send_fn != null and
        windows_winsock_api.sendto_fn != null and
        windows_winsock_api.recv_fn != null and
        windows_winsock_api.recvfrom_fn != null and
        windows_winsock_api.shutdown_fn != null and
        windows_winsock_api.select_fn != null;
}

fn windowsWinsockUnavailable() c_int {
    c.errno = errnoConst("ENOSYS", c.EINVAL);
    return -1;
}

fn windowsSocketFd(sock: WindowsSocket) ?c_int {
    if (comptime builtin.os.tag != .windows) return null;
    windows_socket_mutex.lock();
    defer windows_socket_mutex.unlock();
    for (&windows_socket_entries, 0..) |*entry, i| {
        if (!entry.used) {
            entry.* = .{ .used = true, .socket = sock };
            return windows_socket_base + @as(c_int, @intCast(i));
        }
    }
    return null;
}

fn windowsSocketFromFd(fd: c_int) ?WindowsSocket {
    if (comptime builtin.os.tag != .windows) return null;
    if (fd < windows_socket_base) return null;
    const index = fd - windows_socket_base;
    if (index < 0 or index >= windows_socket_slots) return null;
    windows_socket_mutex.lock();
    defer windows_socket_mutex.unlock();
    const entry = windows_socket_entries[@as(usize, @intCast(index))];
    if (!entry.used) return null;
    return entry.socket;
}

fn closeWindowsSocket(fd: c_int) c_int {
    if (comptime builtin.os.tag != .windows) return errnoConst("ENOSYS", c.EINVAL);
    if (fd < windows_socket_base) return errnoConst("EBADF", c.EINVAL);
    const index = fd - windows_socket_base;
    if (index < 0 or index >= windows_socket_slots) return errnoConst("EBADF", c.EINVAL);
    windows_socket_mutex.lock();
    defer windows_socket_mutex.unlock();
    const entry = &windows_socket_entries[@as(usize, @intCast(index))];
    if (!entry.used) return errnoConst("EBADF", c.EINVAL);
    std.os.windows.closesocket(entry.socket) catch {
        return errnoConst("EIO", c.EINVAL);
    };
    entry.* = .{};
    return 0;
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

fn drainWindowsPipeStream(stream: *c.FILE) void {
    if (comptime builtin.os.tag != .windows) return;
    const fd = fileno(stream);
    if (fd < 0) return;
    const status_flags = winfd.getStatusFlags(fd) orelse return;
    if ((status_flags & 0x3) != c.O_RDONLY) return;

    var buf: [256]u8 = undefined;
    while (true) {
        var amt_read: u32 = 0;
        if (std.os.windows.kernel32.ReadFile(stream.fd.?, &buf, buf.len, &amt_read, null) == 0) {
            switch (std.os.windows.kernel32.GetLastError()) {
                .BROKEN_PIPE, .HANDLE_EOF => break,
                else => break,
            }
        }
        if (amt_read == 0) break;
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

fn currentFallbackUmask() c.mode_t {
    fallback_umask_mutex.lock();
    defer fallback_umask_mutex.unlock();
    return fallback_umask;
}

fn applyCreateModeUmask(mode: c_uint) c_uint {
    if (builtin.os.tag == .linux) return mode;
    return mode & ~@as(c_uint, currentFallbackUmask());
}

fn zopenRaw(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int {
    const create_mode = applyCreateModeUmask(mode);
    if (builtin.os.tag.isDarwin()) {
        const darwin_flags = translateDarwinOpenFlags(oflag);
        if (darwin_flags == -1) return -1;
        const rc = darwin.@"open$NOCANCEL"(path, darwin_flags, create_mode);
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

        const attributes: u32 = if ((oflag & c.O_CREAT) != 0 and (create_mode & 0o222) == 0)
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

        const fd_flags: c_int = if ((oflag & c.O_CLOEXEC) != 0) c.FD_CLOEXEC else 0;
        return winfd.allocHandleFlags(handle.?, oflag, fd_flags) catch {
            _ = winapi.CloseHandle(handle.?);
            c.errno = errnoConst("EMFILE", c.ENOMEM);
            return -1;
        };
    }
    const flags_bits: u32 = @bitCast(oflag);
    const flags: os.O = @bitCast(flags_bits);
    const rc = os.system.open(path, flags, @as(std.posix.mode_t, @intCast(create_mode)));
    switch (os.errno(rc)) {
        .SUCCESS => return @as(c_int, @intCast(rc)),
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

fn isWindowsAbsolutePath(path: [*:0]const u8) bool {
    if (path[0] == '/') return true;
    return std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn zopenAtRaw(dirfd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int {
    const create_mode = applyCreateModeUmask(mode);
    if (builtin.os.tag == .windows) {
        if (dirfd == c.AT_FDCWD or isWindowsAbsolutePath(path)) {
            return zopenRaw(path, oflag, create_mode);
        }
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }
    if (builtin.os.tag.isDarwin()) {
        const darwin_flags = translateDarwinOpenFlags(oflag);
        if (darwin_flags == -1) return -1;
        const rc = syscall(darwin_syscall.openat, dirfd, path, darwin_flags, create_mode);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @intCast(rc);
    }

    const flags_bits: u32 = @bitCast(oflag);
    const flags: os.O = @bitCast(flags_bits);
    const openat_sym = if (builtin.os.tag == .linux and @hasDecl(os.system, "openat64"))
        os.system.openat64
    else
        os.system.openat;
    const rc = openat_sym(dirfd, path, flags, @as(std.posix.mode_t, @intCast(create_mode)));
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

fn darwinAccessMask(st: c.struct_stat) c_int {
    var mask: c_int = 0;
    if ((st.st_mode & 0o444) != 0) mask |= c.R_OK;
    if ((st.st_mode & 0o222) != 0) mask |= c.W_OK;
    if ((st.st_mode & 0o111) != 0) mask |= c.X_OK;
    return mask;
}

fn _zopen(path: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.c) c_int {
    return zopenRaw(path, oflag, mode);
}

comptime {
    exportInternalSymbol(&_zopen, "_zopen");
}

fn _zopenat(dirfd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.c) c_int {
    return zopenAtRaw(dirfd, path, oflag, mode);
}

comptime {
    exportInternalSymbol(&_zopenat, "_zopenat");
}

fn windowsSettableStatusFlags() c_int {
    return c.O_APPEND | c.O_NONBLOCK;
}

fn normalizeWindowsStatusFlags(old_flags: c_int, new_flags: c_int) c_int {
    const access_mode = old_flags & 0x3;
    return access_mode | (new_flags & windowsSettableStatusFlags());
}

fn _fcntlArgInt(fd: c_int, cmd: c_int, arg: c_int) callconv(.c) c_int {
    if (builtin.os.tag == .windows) {
        switch (cmd) {
            c.F_GETFD => {
                const flags = winfd.getFdFlags(fd) orelse {
                    c.errno = errnoConst("EBADF", c.EINVAL);
                    return -1;
                };
                return flags;
            },
            c.F_SETFD => {
                const rc = winfd.setFdFlags(fd, arg);
                if (rc != 0) {
                    c.errno = rc;
                    return -1;
                }
                return 0;
            },
            c.F_GETFL => {
                const flags = winfd.getStatusFlags(fd) orelse {
                    c.errno = errnoConst("EBADF", c.EINVAL);
                    return -1;
                };
                return flags;
            },
            c.F_SETFL => {
                const old_flags = winfd.getStatusFlags(fd) orelse {
                    c.errno = errnoConst("EBADF", c.EINVAL);
                    return -1;
                };
                if (!winfd.setStatusFlags(fd, normalizeWindowsStatusFlags(old_flags, arg))) {
                    c.errno = errnoConst("EBADF", c.EINVAL);
                    return -1;
                }
                return 0;
            },
            c.F_DUPFD => {
                if (arg < 0) {
                    c.errno = c.EINVAL;
                    return -1;
                }
                const rc = winfd.dupFd(fd, arg);
                if (rc < 0) {
                    c.errno = -rc;
                    return -1;
                }
                return rc;
            },
            else => {
                c.errno = errnoConst("ENOSYS", c.EINVAL);
                return -1;
            },
        }
    }

    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.fcntl, fd, cmd, arg);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @intCast(rc);
    }

    while (true) {
        const rc = os.system.fcntl(fd, cmd, @as(usize, @bitCast(@as(isize, @intCast(arg)))));
        switch (os.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }
}

comptime {
    // `fcntl` is variadic in the public ABI, so keep the varargs shim in C and
    // route it into this fixed-signature Zig helper. That avoids relying on Zig
    // to define variadic functions directly while still keeping the platform
    // logic here, where we can test it across Linux, Darwin, and Windows.
    exportInternalSymbol(&_fcntlArgInt, "_fcntlArgInt");
}

export fn readv(fd: c_int, iov: [*]const c.struct_iovec, iovcnt: c_int) callconv(.c) isize {
    if (iovcnt < 0) {
        c.errno = c.EINVAL;
        return -1;
    }
    var total: usize = 0;
    var index: usize = 0;
    const count: usize = @intCast(iovcnt);
    while (index < count) : (index += 1) {
        const part = iov[index];
        if (part.iov_len == 0) continue;
        const rc = zreadRaw(fd, @ptrCast(part.iov_base), part.iov_len);
        if (rc < 0) {
            if (total != 0) return @as(isize, @intCast(total));
            return -1;
        }
        const got: usize = @intCast(rc);
        total += got;
        if (got < part.iov_len) break;
    }
    return @as(isize, @intCast(total));
}

export fn writev(fd: c_int, iov: [*]const c.struct_iovec, iovcnt: c_int) callconv(.c) isize {
    if (iovcnt < 0) {
        c.errno = c.EINVAL;
        return -1;
    }
    var total: usize = 0;
    var index: usize = 0;
    const count: usize = @intCast(iovcnt);
    while (index < count) : (index += 1) {
        const part = iov[index];
        if (part.iov_len == 0) continue;
        const rc = zwriteRaw(fd, @ptrCast(part.iov_base), part.iov_len);
        if (rc < 0) {
            if (total != 0) return @as(isize, @intCast(total));
            return -1;
        }
        const wrote: usize = @intCast(rc);
        total += wrote;
        if (wrote < part.iov_len) break;
    }
    return @as(isize, @intCast(total));
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
            // `_popen(..., "r")` captures stdout only. Redirecting stderr into the
            // same pipe changes native Windows shell behavior and can perturb the
            // observed `_pclose()` status even when the command itself succeeds.
            winproc.spawnShell(command, null, child_handle, null, true, &spawn_errno)
        else
            winproc.spawnShell(command, child_handle, null, null, true, &spawn_errno);
        if (process_handle == null) {
            _ = winapi.CloseHandle(read_handle);
            _ = winapi.CloseHandle(write_handle);
            c.errno = spawn_errno;
            return null;
        }
        _ = winapi.CloseHandle(child_handle);

        const parent_fd = winfd.allocHandleFlags(
            parent_handle,
            if (mode_ch == 'r') c.O_RDONLY else c.O_WRONLY,
            0,
        ) catch {
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
    if (builtin.os.tag == .windows) {
        // Native Windows shells can surface a broken-pipe exit status if the
        // parent closes the read end before draining the child's final writes.
        // Drain any unread pipe data first so `_pclose`-style callers get the
        // child exit code rather than an artifact of our teardown ordering.
        drainWindowsPipeStream(stream);
    }
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
        if (windowsSocketFromFd(fd) != null) {
            const close_errno = closeWindowsSocket(fd);
            if (close_errno == 0) return 0;
            c.errno = close_errno;
            return -1;
        }
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
        const valid_bits = c.R_OK | c.W_OK | c.X_OK;
        if ((amode & ~(valid_bits | c.F_OK)) != 0) {
            c.errno = c.EINVAL;
            return -1;
        }
        const open_flags = if ((amode & c.W_OK) != 0 and (amode & c.R_OK) != 0)
            c.O_RDWR
        else if ((amode & c.W_OK) != 0)
            c.O_WRONLY
        else
            c.O_RDONLY;
        const fd = zopenRaw(path, open_flags, 0);
        if (fd < 0) return -1;
        defer _ = close(fd);
        if ((amode & c.X_OK) != 0) {
            var st: c.struct_stat = undefined;
            if (fstat(fd, &st) != 0) return -1;
            if ((darwinAccessMask(st) & c.X_OK) == 0) {
                c.errno = c.EACCES;
                return -1;
            }
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

fn socketErrno(err: anyerror) c_int {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => c.EACCES,
        error.AddressFamilyNotSupported => errnoConst("EAFNOSUPPORT", c.EINVAL),
        error.ProtocolFamilyNotAvailable => errnoConst("EPROTONOSUPPORT", c.EINVAL),
        error.ProtocolNotSupported => errnoConst("EPROTONOSUPPORT", c.EINVAL),
        error.SocketTypeNotSupported => errnoConst("ESOCKTNOSUPPORT", c.EINVAL),
        error.ProcessFdQuotaExceeded => errnoConst("EMFILE", c.ENOMEM),
        error.SystemFdQuotaExceeded => errnoConst("ENFILE", c.ENOMEM),
        error.SystemResources, error.NetworkSubsystemFailed => c.ENOMEM,
        error.AddressInUse => errnoConst("EADDRINUSE", c.EINVAL),
        error.AddressNotAvailable => errnoConst("EADDRNOTAVAIL", c.EINVAL),
        error.FileDescriptorNotASocket => errnoConst("ENOTSOCK", c.EINVAL),
        error.AlreadyBound => errnoConst("EINVAL", c.EINVAL),
        error.SymLinkLoop => errnoConst("ELOOP", c.EINVAL),
        error.NameTooLong => errnoConst("ENAMETOOLONG", c.EINVAL),
        error.FileNotFound => c.ENOENT,
        error.NotDir => errnoConst("ENOTDIR", c.EINVAL),
        error.ReadOnlyFileSystem => errnoConst("EROFS", c.EACCES),
        error.ConnectionPending, error.WouldBlock => errnoConst("EWOULDBLOCK", c.EAGAIN),
        error.ConnectionRefused => errnoConst("ECONNREFUSED", c.EINVAL),
        error.ConnectionResetByPeer => errnoConst("ECONNRESET", c.EINVAL),
        error.ConnectionTimedOut => errnoConst("ETIMEDOUT", c.EINVAL),
        error.NetworkUnreachable => errnoConst("ENETUNREACH", c.EINVAL),
        error.SocketNotConnected => errnoConst("ENOTCONN", c.EINVAL),
        error.ConnectionAborted => errnoConst("ECONNABORTED", c.EINVAL),
        error.BlockingOperationInProgress => errnoConst("EINPROGRESS", c.EAGAIN),
        error.MessageTooBig => errnoConst("EMSGSIZE", c.EINVAL),
        error.BrokenPipe => errnoConst("EPIPE", c.EINVAL),
        error.UnreachableAddress => errnoConst("EINVAL", c.EINVAL),
        error.SocketNotBound => errnoConst("EINVAL", c.EINVAL),
        error.FastOpenAlreadyInProgress => errnoConst("EALREADY", c.EINVAL),
        else => errnoConst("EIO", c.EINVAL),
    };
}

fn windowsSocketErrno() c_int {
    if (comptime builtin.os.tag != .windows) return errnoConst("ENOSYS", c.EINVAL);
    return switch (std.os.windows.ws2_32.WSAGetLastError()) {
        .WSAEACCES => c.EACCES,
        .WSAEADDRINUSE => errnoConst("EADDRINUSE", c.EINVAL),
        .WSAEADDRNOTAVAIL => errnoConst("EADDRNOTAVAIL", c.EINVAL),
        .WSAEAFNOSUPPORT => errnoConst("EAFNOSUPPORT", c.EINVAL),
        .WSAEWOULDBLOCK => errnoConst("EWOULDBLOCK", c.EAGAIN),
        .WSAECONNREFUSED => errnoConst("ECONNREFUSED", c.EINVAL),
        .WSAECONNRESET => errnoConst("ECONNRESET", c.EINVAL),
        .WSAETIMEDOUT => errnoConst("ETIMEDOUT", c.EINVAL),
        .WSAEINPROGRESS => errnoConst("EINPROGRESS", c.EINVAL),
        .WSAEALREADY => errnoConst("EALREADY", c.EINVAL),
        .WSAEISCONN => errnoConst("EISCONN", c.EINVAL),
        .WSAENOTCONN => errnoConst("ENOTCONN", c.EINVAL),
        .WSAENOTSOCK => errnoConst("ENOTSOCK", c.EINVAL),
        .WSAEMSGSIZE => errnoConst("EMSGSIZE", c.EINVAL),
        .WSAEINVAL => c.EINVAL,
        .WSAENOPROTOOPT => errnoConst("ENOPROTOOPT", c.EINVAL),
        .WSAEPROTONOSUPPORT => errnoConst("EPROTONOSUPPORT", c.EINVAL),
        .WSAESOCKTNOSUPPORT => errnoConst("ESOCKTNOSUPPORT", c.EINVAL),
        .WSAEOPNOTSUPP => errnoConst("EOPNOTSUPP", c.EINVAL),
        .WSAENETDOWN, .WSAENOBUFS => c.ENOMEM,
        else => errnoConst("EIO", c.EINVAL),
    };
}

fn rawSocketFd(fd: c_int) ?std.posix.socket_t {
    if (builtin.os.tag == .windows) {
        return windowsSocketFromFd(fd);
    }
    if (fd < 0) return null;
    return @as(std.posix.socket_t, @intCast(fd));
}

export fn socket(domain: c_int, sock_type: c_int, protocol: c_int) callconv(.c) c_int {
    trace.log("socket domain={} type={} protocol={}", .{ domain, sock_type, protocol });
    if (builtin.os.tag == .windows) {
        ensureWindowsSockets();
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        const sock = windows_winsock_api.socket_fn.?(domain, sock_type, protocol);
        if (sock == std.os.windows.ws2_32.INVALID_SOCKET) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return windowsSocketFd(sock) orelse blk: {
            _ = std.os.windows.ws2_32.closesocket(sock);
            c.errno = errnoConst("EMFILE", c.ENOMEM);
            break :blk -1;
        };
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.socket, domain, sock_type, protocol);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(c_int, @intCast(rc));
    }
    const sock = std.posix.socket(
        @as(u32, @intCast(domain)),
        @as(u32, @intCast(sock_type)),
        @as(u32, @intCast(protocol)),
    ) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return @as(c_int, @intCast(sock));
}

export fn bind(sockfd: c_int, addr: ?*const c.struct_sockaddr, addrlen: c.socklen_t) callconv(.c) c_int {
    trace.log("bind fd={} addrlen={}", .{ sockfd, addrlen });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        const name = addr orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        if (windows_winsock_api.bind_fn.?(sock, @ptrCast(name), @intCast(addrlen)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const name = addr orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const rc = syscall(darwin_syscall.bind, sock, name, addrlen);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.bind(sock, @ptrCast(addr orelse {
        c.errno = c.EINVAL;
        return -1;
    }), @intCast(addrlen)) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn connect(sockfd: c_int, address: ?*const c.struct_sockaddr, address_len: c.socklen_t) callconv(.c) c_int {
    trace.log("connect fd={} addrlen={}", .{ sockfd, address_len });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        if (windows_winsock_api.connect_fn.?(sock, @ptrCast(name), @intCast(address_len)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const rc = syscall(darwin_syscall.connect, sock, name, address_len);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.connect(sock, @ptrCast(address orelse {
        c.errno = c.EINVAL;
        return -1;
    }), @intCast(address_len)) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn getsockname(sockfd: c_int, address: ?*c.struct_sockaddr, address_len: ?*c.socklen_t) callconv(.c) c_int {
    trace.log("getsockname fd={}", .{sockfd});
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const len_ptr = address_len orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        if (windows_winsock_api.getsockname_fn.?(sock, @ptrCast(name), @ptrCast(len_ptr)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const len_ptr = address_len orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const rc = syscall(darwin_syscall.getsockname, sock, name, len_ptr);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.getsockname(sock, @ptrCast(address orelse {
        c.errno = c.EINVAL;
        return -1;
    }), @ptrCast(address_len orelse {
        c.errno = c.EINVAL;
        return -1;
    })) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn getpeername(sockfd: c_int, address: ?*c.struct_sockaddr, address_len: ?*c.socklen_t) callconv(.c) c_int {
    trace.log("getpeername fd={}", .{sockfd});
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const len_ptr = address_len orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        if (windows_winsock_api.getpeername_fn.?(sock, @ptrCast(name), @ptrCast(len_ptr)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const name = address orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const len_ptr = address_len orelse {
            c.errno = c.EINVAL;
            return -1;
        };
        const rc = syscall(darwin_syscall.getpeername, sock, name, len_ptr);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.getpeername(sock, @ptrCast(address orelse {
        c.errno = c.EINVAL;
        return -1;
    }), @ptrCast(address_len orelse {
        c.errno = c.EINVAL;
        return -1;
    })) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn getsockopt(sockfd: c_int, level: c_int, option_name: c_int, option_value: ?*anyopaque, option_len: ?*c.socklen_t) callconv(.c) c_int {
    trace.log("getsockopt fd={} level={} opt={}", .{ sockfd, level, option_name });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    const len_ptr = option_len orelse {
        c.errno = c.EINVAL;
        return -1;
    };
    const out_ptr = option_value orelse {
        c.errno = c.EINVAL;
        return -1;
    };
    const opt_buf: [*]u8 = @ptrCast(out_ptr);
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        if (windows_winsock_api.getsockopt_fn.?(sock, level, option_name, opt_buf, @ptrCast(len_ptr)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.getsockopt, sock, level, option_name, out_ptr, len_ptr);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.getsockopt(sock, level, @as(u32, @intCast(option_name)), opt_buf[0..@intCast(len_ptr.*)]) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn setsockopt(sockfd: c_int, level: c_int, option_name: c_int, option_value: ?*const anyopaque, option_len: c.socklen_t) callconv(.c) c_int {
    trace.log("setsockopt fd={} level={} opt={} len={}", .{ sockfd, level, option_name, option_len });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    const in_ptr = option_value orelse {
        c.errno = c.EINVAL;
        return -1;
    };
    const opt_buf: [*]const u8 = @ptrCast(in_ptr);
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        if (windows_winsock_api.setsockopt_fn.?(sock, level, option_name, opt_buf, @intCast(option_len)) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.setsockopt, sock, level, option_name, in_ptr, option_len);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    std.posix.setsockopt(sock, level, @as(u32, @intCast(option_name)), opt_buf[0..@intCast(option_len)]) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn sendto(sockfd: c_int, message: ?*const anyopaque, len: usize, flags: c_int, dest_addr: ?*const c.struct_sockaddr, dest_len: c.socklen_t) callconv(.c) isize {
    trace.log("sendto fd={} len={} flags={} has_dest={}", .{ sockfd, len, flags, dest_addr != null });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    const data_ptr: [*]const u8 = if (len == 0)
        @ptrFromInt(@intFromPtr(""))
    else
        @ptrCast(message orelse {
            c.errno = c.EINVAL;
            return -1;
        });
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) {
            c.errno = errnoConst("ENOSYS", c.EINVAL);
            return -1;
        }
        const max_len: usize = @min(len, @as(usize, std.math.maxInt(c_int)));
        const rc = if (dest_addr) |to|
            windows_winsock_api.sendto_fn.?(sock, data_ptr, @intCast(max_len), flags, @ptrCast(to), @intCast(dest_len))
        else
            windows_winsock_api.send_fn.?(sock, data_ptr, @intCast(max_len), @as(u32, @bitCast(flags)));
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(
            darwin_syscall.sendto,
            sock,
            data_ptr,
            len,
            flags,
            dest_addr,
            dest_len,
        );
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    const written = std.posix.sendto(sock, data_ptr[0..len], @as(u32, @intCast(flags)), @ptrCast(dest_addr), @intCast(dest_len)) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return @as(isize, @intCast(written));
}

export fn recv(sockfd: c_int, buffer: ?*anyopaque, length: usize, flags: c_int) callconv(.c) isize {
    trace.log("recv fd={} len={} flags={}", .{ sockfd, length, flags });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    const buf_ptr: [*]u8 = if (length == 0)
        @ptrFromInt(@intFromPtr(""))
    else
        @ptrCast(buffer orelse {
            c.errno = c.EINVAL;
            return -1;
        });
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) {
            c.errno = errnoConst("ENOSYS", c.EINVAL);
            return -1;
        }
        const max_len: usize = @min(length, @as(usize, std.math.maxInt(c_int)));
        const rc = windows_winsock_api.recv_fn.?(sock, buf_ptr, @intCast(max_len), flags);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.recvfrom, sock, buf_ptr, length, flags, @as(?*c.struct_sockaddr, null), @as(?*c.socklen_t, null));
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    const got = std.posix.recv(sock, buf_ptr[0..length], @as(u32, @intCast(flags))) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return @as(isize, @intCast(got));
}

export fn recvfrom(sockfd: c_int, buffer: ?*anyopaque, length: usize, flags: c_int, address: ?*c.struct_sockaddr, address_len: ?*c.socklen_t) callconv(.c) isize {
    trace.log("recvfrom fd={} len={} flags={}", .{ sockfd, length, flags });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    const buf_ptr: [*]u8 = if (length == 0)
        @ptrFromInt(@intFromPtr(""))
    else
        @ptrCast(buffer orelse {
            c.errno = c.EINVAL;
            return -1;
        });
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) {
            c.errno = errnoConst("ENOSYS", c.EINVAL);
            return -1;
        }
        const max_len: usize = @min(length, @as(usize, std.math.maxInt(c_int)));
        const rc = windows_winsock_api.recvfrom_fn.?(
            sock,
            buf_ptr,
            @intCast(max_len),
            flags,
            @ptrCast(address),
            @ptrCast(address_len),
        );
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.recvfrom, sock, buf_ptr, length, flags, address, address_len);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(isize, @intCast(rc));
    }
    const got = std.posix.recvfrom(sock, buf_ptr[0..length], @as(u32, @intCast(flags)), @ptrCast(address), @ptrCast(address_len)) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return @as(isize, @intCast(got));
}

export fn shutdown(sockfd: c_int, how: c_int) callconv(.c) c_int {
    trace.log("shutdown fd={} how={}", .{ sockfd, how });
    const sock = rawSocketFd(sockfd) orelse {
        c.errno = errnoConst("ENOTSOCK", c.EINVAL);
        return -1;
    };
    if (builtin.os.tag == .windows) {
        if (!windowsWinsockReady()) return windowsWinsockUnavailable();
        if (windows_winsock_api.shutdown_fn.?(sock, how) == std.os.windows.ws2_32.SOCKET_ERROR) {
            c.errno = windowsSocketErrno();
            return -1;
        }
        return 0;
    }
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.shutdown, sock, how);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return 0;
    }
    const mode: std.posix.ShutdownHow = switch (how) {
        c.SHUT_RD => .recv,
        c.SHUT_WR => .send,
        c.SHUT_RDWR => .both,
        else => {
            c.errno = c.EINVAL;
            return -1;
        },
    };
    std.posix.shutdown(sock, mode) catch |err| {
        c.errno = socketErrno(err);
        return -1;
    };
    return 0;
}

export fn htonl(hostlong: c.in_addr_t) callconv(.c) c.in_addr_t {
    return @byteSwap(hostlong);
}

export fn htons(hostshort: c_ushort) callconv(.c) c_ushort {
    return @byteSwap(hostshort);
}

export fn ntohl(netlong: c.in_addr_t) callconv(.c) c.in_addr_t {
    return @byteSwap(netlong);
}

export fn ntohs(netshort: c_ushort) callconv(.c) c_ushort {
    return @byteSwap(netshort);
}

fn parseIpv4(text: []const u8) ?c.in_addr_t {
    var iter = std.mem.splitScalar(u8, text, '.');
    var parts: [4]u8 = undefined;
    var idx: usize = 0;
    while (iter.next()) |piece| {
        if (idx >= parts.len or piece.len == 0) return null;
        const value = std.fmt.parseUnsigned(u8, piece, 10) catch return null;
        parts[idx] = value;
        idx += 1;
    }
    if (idx != parts.len) return null;
    const host_value: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
    return htonl(host_value);
}

fn formatIpv4(buf: []u8, addr: c.in_addr_t) []const u8 {
    const host = ntohl(addr);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        (host >> 24) & 0xff,
        (host >> 16) & 0xff,
        (host >> 8) & 0xff,
        host & 0xff,
    }) catch "";
}

export fn inet_addr(cp: [*:0]const u8) callconv(.c) c.in_addr_t {
    return parseIpv4(std.mem.span(cp)) orelse ~@as(c.in_addr_t, 0);
}

export fn inet_ntoa(input: c.struct_in_addr) callconv(.c) [*:0]u8 {
    hostent_state.mutex.lock();
    defer hostent_state.mutex.unlock();
    const rendered = formatIpv4(hostent_state.name_buf[0 .. hostent_state.name_buf.len - 1], input.s_addr);
    @memset(hostent_state.name_buf[rendered.len..], 0);
    return @ptrCast(&hostent_state.name_buf);
}

fn fillHostent(name: []const u8, addr: c.in_addr_t) *c.struct_hostent {
    hostent_state.mutex.lock();
    defer hostent_state.mutex.unlock();
    const name_len = @min(name.len, hostent_state.name_buf.len - 1);
    @memcpy(hostent_state.name_buf[0..name_len], name[0..name_len]);
    @memset(hostent_state.name_buf[name_len..], 0);
    std.mem.writeInt(u32, hostent_state.addr_buf[0..4], addr, .big);
    hostent_state.addr_list[0] = @ptrCast(&hostent_state.addr_buf);
    hostent_state.addr_list[1] = null;
    hostent_state.hostent.h_name = @ptrCast(&hostent_state.name_buf);
    hostent_state.hostent.h_aliases = @ptrCast(&hostent_state.aliases);
    hostent_state.hostent.h_addrtype = c.AF_INET;
    hostent_state.hostent.h_length = 4;
    hostent_state.hostent.h_addr_list = @ptrCast(&hostent_state.addr_list);
    return &hostent_state.hostent;
}

export fn gethostbyname(name: [*:0]const u8) callconv(.c) ?*c.struct_hostent {
    const text = std.mem.span(name);
    if (std.ascii.eqlIgnoreCase(text, "localhost")) {
        return fillHostent("localhost", htonl(c.INADDR_LOOPBACK));
    }
    const parsed = parseIpv4(text) orelse return null;
    return fillHostent(text, parsed);
}

export fn gethostbyaddr(addr: ?*const anyopaque, len: c.socklen_t, typ: c_int) callconv(.c) ?*c.struct_hostent {
    if (typ != c.AF_INET or len != 4 or addr == null) return null;
    const bytes: *const [4]u8 = @ptrCast(@alignCast(addr));
    const raw = std.mem.readInt(u32, bytes, .big);
    if (raw == htonl(c.INADDR_LOOPBACK)) {
        return fillHostent("localhost", raw);
    }
    var buf: [16]u8 = undefined;
    const rendered = formatIpv4(&buf, raw);
    return fillHostent(rendered, raw);
}

fn pathconfLinkMax() c_long {
    // Keep this limited to the one `_PC_*` selector exposed by our public header.
    // Callers only need a stable positive bound here; exact filesystem-dependent
    // values can vary widely even within the same OS.
    return if (builtin.os.tag == .windows) 1024 else 127;
}

export fn fpathconf(fileds: c_int, name: c_int) callconv(.c) c_long {
    if (fileds < 0) {
        c.errno = errnoConst("EBADF", c.EINVAL);
        return -1;
    }
    if (builtin.os.tag == .windows) {
        if (winfd.handleFromFd(fileds) == null) {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return -1;
        }
    } else {
        switch (os.errno(os.system.fcntl(fileds, c.F_GETFD, @as(usize, 0)))) {
            .SUCCESS => {},
            .BADF => {
                c.errno = errnoConst("EBADF", c.EINVAL);
                return -1;
            },
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
    }
    switch (name) {
        c._PC_LINK_MAX => return pathconfLinkMax(),
        else => {
            c.errno = c.EINVAL;
            return -1;
        },
    }
}

export fn pathconf(path: [*:0]const u8, name: c_int) callconv(.c) c_long {
    switch (name) {
        c._PC_LINK_MAX => {},
        else => {
            c.errno = c.EINVAL;
            return -1;
        },
    }
    if (access(path, 0) != 0) return -1;
    return pathconfLinkMax();
}

export fn gethostname(name: [*]u8, namelen: usize) callconv(.c) c_int {
    if (namelen == 0) {
        c.errno = c.EINVAL;
        return -1;
    }
    if (builtin.os.tag == .windows) {
        var size: u32 = @intCast(@min(namelen, @as(usize, std.math.maxInt(u32))));
        if (winapi.GetComputerNameA(name, &size) == 0) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }
        if (@as(usize, size) < namelen) name[@intCast(size)] = 0;
        return 0;
    }
    const uts = std.posix.uname();
    const host = std.mem.sliceTo(&uts.nodename, 0);
    const copy_len = @min(host.len, namelen - 1);
    @memcpy(name[0..copy_len], host[0..copy_len]);
    name[copy_len] = 0;
    if (copy_len != host.len) {
        c.errno = errnoConst("ENAMETOOLONG", c.EINVAL);
        return -1;
    }
    return 0;
}

export fn link(path1: [*:0]const u8, path2: [*:0]const u8) callconv(.c) c_int {
    if (builtin.os.tag == .windows) {
        if (winapi.CreateHardLinkA(path2, path1, null) == 0) {
            c.errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return -1;
        }
        return 0;
    }
    switch (os.errno(os.system.linkat(os.AT.FDCWD, path1, os.AT.FDCWD, path2, 0))) {
        .SUCCESS => return 0,
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
}

export fn unlink(path: [*:0]const u8) callconv(.c) c_int {
    if (builtin.os.tag.isDarwin()) {
        switch (os.errno(os.system.unlinkat(c.AT_FDCWD, path, 0))) {
            .SUCCESS => return 0,
            else => |e| {
                c.errno = @intFromEnum(e);
                return -1;
            },
        }
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

export fn sleep(seconds: c_uint) callconv(.c) c_uint {
    if (seconds == 0) return 0;
    std.Thread.sleep(@as(u64, seconds) * std.time.ns_per_s);
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

    var size: c.winsize = undefined;
    // Darwin and Linux use different `TIOCGWINSZ` request numbers. Reusing the
    // Linux constant on Darwin regresses native macOS and Darling by sending an
    // ioctl the target kernel/emulator does not understand.
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

const DarwinTimeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_int,
};

const DarwinItimerval = extern struct {
    it_interval: DarwinTimeval,
    it_value: DarwinTimeval,
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

fn cTimevalToDarwin(tv: c.timeval) DarwinTimeval {
    return .{
        .tv_sec = @as(c_long, @intCast(tv.tv_sec)),
        .tv_usec = @as(c_int, @intCast(tv.tv_usec)),
    };
}

fn darwinTimevalToC(tv: DarwinTimeval) c.timeval {
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
        var native_value: DarwinItimerval = undefined;
        const rc = syscall(darwin_syscall.getitimer, which, &native_value);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        value.it_interval = darwinTimevalToC(native_value.it_interval);
        value.it_value = darwinTimevalToC(native_value.it_value);
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
        if (!cPtrIsNull(avalue)) avalue.* = windowsCurrentItimerLocked();
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
        var native_value = DarwinItimerval{
            .it_interval = cTimevalToDarwin(value.it_interval),
            .it_value = cTimevalToDarwin(value.it_value),
        };
        var native_old: DarwinItimerval = undefined;
        const rc = syscall(
            darwin_syscall.setitimer,
            which,
            &native_value,
            if (!cPtrIsNull(avalue)) &native_old else @as(?*DarwinItimerval, null),
        );
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        if (!cPtrIsNull(avalue)) {
            avalue.it_interval = darwinTimevalToC(native_old.it_interval);
            avalue.it_value = darwinTimevalToC(native_old.it_value);
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
        if (!cPtrIsNull(avalue)) @intFromPtr(&linux_old) else 0,
    );
    switch (os.errno(rc)) {
        .SUCCESS => {
            if (!cPtrIsNull(avalue)) {
                avalue.it_interval = linuxTimevalToC(linux_old.it_interval);
                avalue.it_value = linuxTimevalToC(linux_old.it_value);
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

fn cPtrIsNull(ptr: anytype) bool {
    return @intFromPtr(ptr) == 0;
}

export fn sigaction(sig: c_int, act: *const c.struct_sigaction, oact: *c.struct_sigaction) callconv(.c) c_int {
    trace.log("sigaction sig={}", .{sig});
    if (builtin.os.tag == .windows) {
        return cstd.__zwindows_sigaction(sig, act, oact);
    }
    if (builtin.os.tag.isDarwin()) {
        var native_act = std.mem.zeroes(std.c.Sigaction);
        const native_act_ptr: ?*std.c.Sigaction = if (!cPtrIsNull(act)) blk: {
            const new_act = act;
            native_act.mask = cSigsetToDarwin(new_act.sa_mask);
            native_act.flags = @as(c_uint, @bitCast(new_act.sa_flags));
            if ((native_act.flags & std.c.SA.SIGINFO) != 0) {
                native_act.handler.sigaction = if (new_act.sa_sigaction) |f|
                    @as(?std.c.Sigaction.sigaction_fn, @ptrFromInt(@intFromPtr(f)))
                else
                    null;
            } else {
                native_act.handler.handler = if (new_act.sa_handler) |h|
                    @as(?std.c.Sigaction.handler_fn, @ptrFromInt(@intFromPtr(h)))
                else
                    null;
            }
            break :blk &native_act;
        } else null;

        var native_old = std.mem.zeroes(std.c.Sigaction);
        const native_old_ptr: ?*std.c.Sigaction = if (!cPtrIsNull(oact)) &native_old else null;
        const rc = syscall(darwin_syscall.sigaction, sig, native_act_ptr, native_old_ptr);
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        if (!cPtrIsNull(oact)) {
            const old_act = oact;
            old_act.sa_mask = darwinSigsetToC(native_old.mask);
            old_act.sa_flags = @as(c_int, @bitCast(native_old.flags));
            if ((native_old.flags & std.c.SA.SIGINFO) != 0) {
                old_act.sa_sigaction = if (native_old.handler.sigaction) |f|
                    @as(@TypeOf(old_act.sa_sigaction), @ptrFromInt(@intFromPtr(f)))
                else
                    null;
                old_act.sa_handler = null;
            } else {
                old_act.sa_handler = if (native_old.handler.handler) |h|
                    @as(@TypeOf(old_act.sa_handler), @ptrFromInt(@intFromPtr(h)))
                else
                    null;
                old_act.sa_sigaction = null;
            }
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

    var linux_act: std.os.linux.Sigaction = undefined;
    const linux_act_ptr: ?*std.os.linux.Sigaction = if (!cPtrIsNull(act)) blk: {
        const new_act = act;
        const flags_bits: c_uint = @bitCast(new_act.sa_flags);
        linux_act = .{
            .handler = undefined,
            .mask = cSigsetToLinux(new_act.sa_mask),
            .flags = @as(@TypeOf(@as(std.os.linux.Sigaction, undefined).flags), @intCast(flags_bits)),
        };
        if ((flags_bits & std.os.linux.SA.SIGINFO) != 0) {
            linux_act.handler = .{ .sigaction = cSigactionToLinux(new_act.sa_sigaction) };
        } else {
            linux_act.handler = .{ .handler = cHandlerToLinux(new_act.sa_handler) };
        }
        break :blk &linux_act;
    } else null;

    var linux_old: std.os.linux.Sigaction = undefined;
    const rc = std.os.linux.sigaction(
        @as(u8, @intCast(sig)),
        linux_act_ptr,
        if (!cPtrIsNull(oact)) &linux_old else null,
    );
    switch (os.errno(rc)) {
        .SUCCESS => {
            if (!cPtrIsNull(oact)) {
                const old_act = oact;
                const old_flags_bits: c_uint = @truncate(@as(usize, @intCast(linux_old.flags)));
                old_act.sa_flags = @as(c_int, @bitCast(old_flags_bits));
                old_act.sa_mask = linuxSigsetToC(linux_old.mask);
                if ((old_flags_bits & std.os.linux.SA.SIGINFO) != 0) {
                    old_act.sa_sigaction = linuxSigactionToC(linux_old.handler.sigaction);
                    old_act.sa_handler = null;
                } else {
                    old_act.sa_handler = linuxHandlerToC(linux_old.handler.handler);
                    old_act.sa_sigaction = null;
                }
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

    // Non-Linux targets in this libc route file creation through our own `open` /
    // `openat` / temp-file helpers, so keep the process-local mask here and apply
    // it when we pass creation modes to the OS. Relying on the host libc's global
    // umask state would break the "independent libc" constraint and regressed
    // platform parity in earlier sweeps.
    fallback_umask_mutex.lock();
    defer fallback_umask_mutex.unlock();
    const old = fallback_umask;
    fallback_umask = mode & 0o777;
    return old;
}

// --------------------------------------------------------------------------------
// dirent
// --------------------------------------------------------------------------------
const dirent_name_cap = 1024;
const DirentStorage = extern struct {
    d_ino: c.ino_t,
    d_name: [dirent_name_cap]u8,
};

const DirImpl = struct {
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    entry: DirentStorage = std.mem.zeroes(DirentStorage),
};

fn fsErrno(err: anyerror) c_int {
    return switch (err) {
        error.AccessDenied => c.EACCES,
        error.PermissionDenied => c.EPERM,
        error.FileNotFound => c.ENOENT,
        error.NotDir => errnoConst("ENOTDIR", c.EINVAL),
        error.NameTooLong => errnoConst("ENAMETOOLONG", c.EINVAL),
        error.SystemResources => c.ENOMEM,
        else => errnoConst("EIO", c.EINVAL),
    };
}

fn dirImplFromOpaque(dirp: *c.DIR) *DirImpl {
    return @ptrCast(@alignCast(dirp));
}

fn openDirPath(dir_name: [*:0]const u8) !std.fs.Dir {
    const path = std.mem.span(dir_name);
    const opts = std.fs.Dir.OpenOptions{ .iterate = true };
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, opts);
    }
    return std.fs.cwd().openDir(path, opts);
}

export fn opendir(dir_name: [*:0]const u8) callconv(.c) ?*c.DIR {
    var dir = openDirPath(dir_name) catch |err| {
        c.errno = fsErrno(err);
        return null;
    };
    const impl = std.heap.page_allocator.create(DirImpl) catch {
        dir.close();
        c.errno = c.ENOMEM;
        return null;
    };
    impl.* = .{
        .dir = dir,
        .iter = dir.iterate(),
    };
    return @ptrCast(impl);
}

export fn fdopendir(fd: c_int) callconv(.c) ?*c.DIR {
    if (fd < 0) {
        c.errno = errnoConst("EBADF", c.EINVAL);
        return null;
    }
    const handle = if (builtin.os.tag == .windows)
        winfd.handleFromFd(fd) orelse {
            c.errno = errnoConst("EBADF", c.EINVAL);
            return null;
        }
    else
        @as(std.fs.Dir.Handle, @intCast(fd));
    const impl = std.heap.page_allocator.create(DirImpl) catch {
        c.errno = c.ENOMEM;
        return null;
    };
    var dir: std.fs.Dir = .{ .fd = handle };
    impl.* = .{
        .dir = dir,
        .iter = dir.iterate(),
    };
    return @ptrCast(impl);
}

export fn closedir(dirp: *c.DIR) callconv(.c) c_int {
    const impl = dirImplFromOpaque(dirp);
    impl.dir.close();
    std.heap.page_allocator.destroy(impl);
    return 0;
}

export fn readdir(dirp: *c.DIR) callconv(.c) ?*DirentStorage {
    const impl = dirImplFromOpaque(dirp);
    const next = impl.iter.next() catch |err| {
        c.errno = fsErrno(err);
        return null;
    };
    const entry = next orelse return null;
    const name_len = @min(entry.name.len, dirent_name_cap - 1);
    @memcpy(impl.entry.d_name[0..name_len], entry.name[0..name_len]);
    impl.entry.d_name[name_len] = 0;
    if (name_len + 1 < impl.entry.d_name.len) {
        @memset(impl.entry.d_name[name_len + 1 ..], 0);
    }

    impl.entry.d_ino = 0;
    if (builtin.os.tag != .windows) {
        const stat_info = std.posix.fstatat(impl.dir.fd, entry.name, std.posix.AT.SYMLINK_NOFOLLOW) catch null;
        if (stat_info) |st| {
            impl.entry.d_ino = @as(c.ino_t, @intCast(st.ino));
        }
    }
    return &impl.entry;
}

// --------------------------------------------------------------------------------
// pthread
// --------------------------------------------------------------------------------
const pthread_slot_count = 64;
const darwin_pthread_mutex_sig_init: c_long = 0x32AAABA7;
const darwin_pthread_cond_sig_init: c_long = 0x3CB0B1BB;
const PthreadMutexEntry = struct {
    used: bool = false,
    locked: AtomicFlag = AtomicFlag.init(0),
};
const PthreadCondEntry = struct {
    used: bool = false,
    seq: AtomicFlag = AtomicFlag.init(0),
};

var pthread_table_lock: AtomicFlag = AtomicFlag.init(0);
var pthread_mutex_entries: [pthread_slot_count]PthreadMutexEntry = [_]PthreadMutexEntry{.{}} ** pthread_slot_count;
var pthread_cond_entries: [pthread_slot_count]PthreadCondEntry = [_]PthreadCondEntry{.{}} ** pthread_slot_count;

fn pthreadOpaqueId(comptime T: type, obj: *T) c_int {
    if (!builtin.os.tag.isDarwin()) return obj.*;
    const storage: [*]const u8 = @ptrCast(&@field(obj.*, "__opaque"));
    return std.mem.readInt(c_int, storage[0..@sizeOf(c_int)], .little);
}

fn setPthreadOpaqueId(comptime T: type, obj: *T, id: c_int) void {
    if (!builtin.os.tag.isDarwin()) {
        obj.* = id;
        return;
    }
    const storage: [*]u8 = @ptrCast(&@field(obj.*, "__opaque"));
    std.mem.writeInt(c_int, storage[0..@sizeOf(c_int)], id, .little);
}

fn resetPthreadOpaque(comptime T: type, obj: *T) void {
    if (!builtin.os.tag.isDarwin()) {
        obj.* = 0;
        return;
    }
    const storage: [*]u8 = @ptrCast(&@field(obj.*, "__opaque"));
    @memset(storage[0..@sizeOf(@TypeOf(@field(obj.*, "__opaque")))], 0);
    @field(obj.*, "__sig") = 0;
}

fn lockPthreadTable() void {
    while (pthread_table_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        spinPause();
    }
}

fn unlockPthreadTable() void {
    pthread_table_lock.store(0, .release);
}

fn allocPthreadSlot(comptime T: type, entries: *[pthread_slot_count]T) ?usize {
    for (entries, 0..) |*entry, i| {
        if (!entry.used) {
            entry.used = true;
            return i;
        }
    }
    return null;
}

fn mutexEntryFor(mutex: *c.pthread_mutex_t, create: bool) ?*PthreadMutexEntry {
    lockPthreadTable();
    defer unlockPthreadTable();
    const id = pthreadOpaqueId(c.pthread_mutex_t, mutex);
    if (id == 0) {
        if (!create) return null;
        const index = allocPthreadSlot(PthreadMutexEntry, &pthread_mutex_entries) orelse return null;
        pthread_mutex_entries[index].locked = AtomicFlag.init(0);
        if (builtin.os.tag.isDarwin()) {
            @field(mutex.*, "__sig") = darwin_pthread_mutex_sig_init;
        }
        setPthreadOpaqueId(c.pthread_mutex_t, mutex, @as(c_int, @intCast(index + 1)));
        return &pthread_mutex_entries[index];
    }
    if (id < 0 or id > pthread_slot_count) return null;
    const entry = &pthread_mutex_entries[@as(usize, @intCast(id - 1))];
    if (!entry.used) return null;
    return entry;
}

fn condEntryFor(cond: *c.pthread_cond_t, create: bool) ?*PthreadCondEntry {
    lockPthreadTable();
    defer unlockPthreadTable();
    const id = pthreadOpaqueId(c.pthread_cond_t, cond);
    if (id == 0) {
        if (!create) return null;
        const index = allocPthreadSlot(PthreadCondEntry, &pthread_cond_entries) orelse return null;
        pthread_cond_entries[index].seq = AtomicFlag.init(0);
        if (builtin.os.tag.isDarwin()) {
            @field(cond.*, "__sig") = darwin_pthread_cond_sig_init;
        }
        setPthreadOpaqueId(c.pthread_cond_t, cond, @as(c_int, @intCast(index + 1)));
        return &pthread_cond_entries[index];
    }
    if (id < 0 or id > pthread_slot_count) return null;
    const entry = &pthread_cond_entries[@as(usize, @intCast(id - 1))];
    if (!entry.used) return null;
    return entry;
}

export fn pthread_mutex_init(mutex: *c.pthread_mutex_t, attr: ?*const c.pthread_mutexattr_t) callconv(.c) c_int {
    trace.log("pthread_mutex_init {*}", .{mutex});
    _ = attr;
    if (mutexEntryFor(mutex, true) == null) return errnoConst("ENOMEM", c.EINVAL);
    return 0;
}

export fn pthread_mutex_destroy(mutex: *c.pthread_mutex_t) callconv(.c) c_int {
    trace.log("pthread_mutex_destroy {*}", .{mutex});
    lockPthreadTable();
    defer unlockPthreadTable();
    const id = pthreadOpaqueId(c.pthread_mutex_t, mutex);
    if (id == 0) return 0;
    if (id < 0 or id > pthread_slot_count) return c.EINVAL;
    if (pthread_mutex_entries[@as(usize, @intCast(id - 1))].locked.load(.acquire) != 0) {
        return errnoConst("EBUSY", c.EINVAL);
    }
    pthread_mutex_entries[@as(usize, @intCast(id - 1))] = .{};
    resetPthreadOpaque(c.pthread_mutex_t, mutex);
    return 0;
}

export fn pthread_mutex_lock(mutex: *c.pthread_mutex_t) callconv(.c) c_int {
    trace.log("pthread_mutex_lock {*}", .{mutex});
    const entry = mutexEntryFor(mutex, true) orelse return errnoConst("ENOMEM", c.EINVAL);
    while (entry.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        spinPause();
    }
    return 0;
}

export fn pthread_mutex_unlock(mutex: *c.pthread_mutex_t) callconv(.c) c_int {
    trace.log("pthread_mutex_unlock {*}", .{mutex});
    const entry = mutexEntryFor(mutex, false) orelse return c.EINVAL;
    if (entry.locked.load(.acquire) == 0) return c.EINVAL;
    entry.locked.store(0, .release);
    return 0;
}

export fn pthread_cond_init(cond: *c.pthread_cond_t, attr: ?*const c.pthread_condattr_t) callconv(.c) c_int {
    trace.log("pthread_cond_init {*}", .{cond});
    _ = attr;
    if (condEntryFor(cond, true) == null) return errnoConst("ENOMEM", c.EINVAL);
    return 0;
}

export fn pthread_cond_destroy(cond: *c.pthread_cond_t) callconv(.c) c_int {
    trace.log("pthread_cond_destroy {*}", .{cond});
    lockPthreadTable();
    defer unlockPthreadTable();
    const id = pthreadOpaqueId(c.pthread_cond_t, cond);
    if (id == 0) return 0;
    if (id < 0 or id > pthread_slot_count) return c.EINVAL;
    pthread_cond_entries[@as(usize, @intCast(id - 1))] = .{};
    resetPthreadOpaque(c.pthread_cond_t, cond);
    return 0;
}

export fn pthread_cond_wait(cond: *c.pthread_cond_t, mutex: *c.pthread_mutex_t) callconv(.c) c_int {
    trace.log("pthread_cond_wait cond={*} mutex={*}", .{ cond, mutex });
    const cond_entry = condEntryFor(cond, true) orelse return errnoConst("ENOMEM", c.EINVAL);
    const target_seq = cond_entry.seq.load(.acquire);
    if (pthread_mutex_unlock(mutex) != 0) return c.EINVAL;
    while (cond_entry.seq.load(.acquire) == target_seq) {
        spinPause();
    }
    if (pthread_mutex_lock(mutex) != 0) return c.EINVAL;
    return 0;
}

export fn pthread_cond_broadcast(cond: *c.pthread_cond_t) callconv(.c) c_int {
    trace.log("pthread_cond_broadcast {*}", .{cond});
    const cond_entry = condEntryFor(cond, false) orelse return c.EINVAL;
    _ = cond_entry.seq.fetchAdd(1, .release);
    return 0;
}

export fn pthread_cond_signal(cond: *c.pthread_cond_t) callconv(.c) c_int {
    trace.log("pthread_cond_signal {*}", .{cond});
    const cond_entry = condEntryFor(cond, false) orelse return c.EINVAL;
    _ = cond_entry.seq.fetchAdd(1, .release);
    return 0;
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

export fn dirname(path: ?[*:0]u8) callconv(.c) [*:0]u8 {
    const input = path orelse return &dirname_dot;
    if (input[0] == 0) return &dirname_dot;

    var end = std.mem.len(input);
    while (end > 1 and input[end - 1] == '/') : (end -= 1) {}

    while (end > 0 and input[end - 1] != '/') : (end -= 1) {}
    if (end == 0) return &dirname_dot;

    while (end > 1 and input[end - 1] == '/') : (end -= 1) {}
    input[end] = 0;

    if (input[0] == 0) return &dirname_root;
    return input;
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

export fn strcasecmp_l(a: [*:0]const u8, b: [*:0]const u8, locale: c.locale_t) callconv(.c) c_int {
    _ = locale;
    return strcasecmp(a, b);
}

export fn strncasecmp_l(a: [*:0]const u8, b: [*:0]const u8, n: usize, locale: c.locale_t) callconv(.c) c_int {
    _ = locale;
    return cstd.strncasecmp(a, b, n);
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

fn windowsSocketReady(sock: WindowsSocket, comptime mode: WindowsSelectMode) ?bool {
    ensureWindowsSockets();
    if (!windowsWinsockReady()) {
        c.errno = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }
    var read_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
    var write_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
    var err_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
    switch (mode) {
        .read => {
            read_set.fd_count = 1;
            read_set.fd_array[0] = sock;
        },
        .write => {
            write_set.fd_count = 1;
            write_set.fd_array[0] = sock;
        },
        .err => {
            err_set.fd_count = 1;
            err_set.fd_array[0] = sock;
        },
    }
    const zero_timeout = std.os.windows.ws2_32.timeval{ .sec = 0, .usec = 0 };
    const rc = windows_winsock_api.select_fn.?(
        0,
        if (mode == .read) &read_set else null,
        if (mode == .write) &write_set else null,
        if (mode == .err) &err_set else null,
        &zero_timeout,
    );
    if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
        c.errno = windowsSocketErrno();
        return null;
    }
    return rc != 0;
}

fn windowsSelectScanSet(comptime mode: WindowsSelectMode, nfds: c_int, fdset: *c.fd_set) ?c_int {
    var ready_count: c_int = 0;
    var fd: c_int = 0;
    while (fd < nfds) : (fd += 1) {
        if (FD_ISSET(fd, fdset) == 0) continue;
        const is_ready = if (windowsSocketFromFd(fd)) |sock|
            windowsSocketReady(sock, mode)
        else blk: {
            const handle = winfd.handleFromFd(fd) orelse {
                c.errno = errnoConst("EBADF", c.EINVAL);
                return null;
            };
            break :blk switch (mode) {
                .read => windowsHandleReadable(handle),
                .write => windowsHandleWritable(handle),
                .err => false,
            };
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
        if (timeout) |ts| {
            if (!cTimespecIsValid(ts.*)) {
                c.errno = c.EINVAL;
                return -1;
            }
        }
        // Darwin has a real pselect(2). Do not collapse this into select():
        // that loses the optional signal mask argument and the atomic mask swap,
        // which changes real native behavior even if an emulator happens to make
        // the timeout-only case look equivalent.
        const rc = syscall(
            darwin_syscall.pselect,
            nfds,
            readfds,
            writefds,
            errorfds,
            timeout,
            sigmask,
        );
        if (rc == -1) {
            c.errno = darwin.__error().*;
            return -1;
        }
        return @as(c_int, @intCast(rc));
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
        var native_times: [2]DarwinTimeval = undefined;
        const native_ptr = if (times) |tv| blk: {
            native_times[0] = cTimevalToDarwin(tv[0]);
            native_times[1] = cTimevalToDarwin(tv[1]);
            break :blk &native_times;
        } else @as(?*[2]DarwinTimeval, null);
        const rc = syscall(darwin_syscall.utimes, filename, native_ptr);
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
