const builtin = @import("builtin");
const std = @import("std");
const winfd = @import("winfd.zig");
const winproc = @import("winproc.zig");

const c = @cImport({
    // problem with LONG_MIN/LONG_MAX, they are currently assuming 64 bit
    //@cInclude("limits.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdarg.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("strings.h");
    @cInclude("setjmp.h");
    @cInclude("locale.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("limits.h");
});

const trace = @import("trace.zig");

extern "c" fn __error() *c_int;
extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn @"open$NOCANCEL"(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

const darwin_syscall = if (builtin.os.tag.isDarwin()) struct {
    const access: c_long = 33;
    const unlink: c_long = 10;
    const rename: c_long = 128;
} else struct {};

const windows_signal_siginfo_bit: c_int = if (@hasDecl(c, "SA_SIGINFO"))
    @as(c_int, @bitCast(@as(c_uint, @intCast(c.SA_SIGINFO))))
else
    0;

fn errnoConst(comptime name: []const u8, fallback: c_int) c_int {
    if (@hasDecl(c, name)) return @field(c, name);
    return fallback;
}

fn translateDarwinOpenFlags(oflag: c_int) c_int {
    if (comptime !builtin.os.tag.isDarwin()) return oflag;

    var flags: std.c.O = .{};
    switch (oflag & 0x3) {
        c.O_RDONLY => flags.ACCMODE = .RDONLY,
        c.O_WRONLY => flags.ACCMODE = .WRONLY,
        c.O_RDWR => flags.ACCMODE = .RDWR,
        else => {
            errno = c.EINVAL;
            return -1;
        },
    }
    if ((oflag & c.O_APPEND) != 0) flags.APPEND = true;
    if ((oflag & c.O_CREAT) != 0) flags.CREAT = true;
    if ((oflag & c.O_EXCL) != 0) flags.EXCL = true;
    if ((oflag & c.O_TRUNC) != 0) flags.TRUNC = true;
    if ((oflag & c.O_NONBLOCK) != 0) flags.NONBLOCK = true;
    if (@hasDecl(c, "O_CLOEXEC") and (oflag & c.O_CLOEXEC) != 0) flags.CLOEXEC = true;
    return @as(c_int, @bitCast(@as(u32, @bitCast(flags))));
}

fn zopenCompat(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int {
    if (builtin.os.tag.isDarwin()) {
        const darwin_flags = translateDarwinOpenFlags(oflag);
        if (darwin_flags == -1) return -1;
        const rc = @"open$NOCANCEL"(path, darwin_flags, mode);
        if (rc == -1) errno = __error().*;
        return rc;
    }

    const flags_bits: u32 = @bitCast(oflag);
    const flags: std.posix.O = @bitCast(flags_bits);
    const rc = std.posix.system.open(path, flags, @as(std.posix.mode_t, @intCast(mode)));
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @as(c_int, @intCast(rc)),
        else => |e| {
            errno = @intFromEnum(e);
            return -1;
        },
    }
}

fn zunlinkCompat(path: [*:0]const u8) c_int {
    if (builtin.os.tag.isDarwin()) {
        switch (std.posix.errno(std.posix.system.unlinkat(c.AT_FDCWD, path, 0))) {
            .SUCCESS => return 0,
            else => |e| {
                errno = @intFromEnum(e);
                return -1;
            },
        }
    }

    std.posix.unlinkZ(path) catch |err| {
        errno = switch (err) {
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

// __main appears to be a design inherited by LLVM from gcc.
// it's typically provided by libgcc and is used to call constructors
fn __main() callconv(.c) void {
    stdin.fd = std.os.windows.peb().ProcessParameters.hStdInput;
    stdout.fd = std.os.windows.peb().ProcessParameters.hStdOutput;
    stderr.fd = std.os.windows.peb().ProcessParameters.hStdError;

    // This startup path does not currently run C/C++ static constructors.
}
comptime {
    if (builtin.os.tag == .windows) @export(&__main, .{ .name = "__main" });
}

const windows = struct {
    const HANDLE = std.os.windows.HANDLE;

    // always sets out_written, even if it returns an error
    fn writeAll(hFile: HANDLE, buffer: []const u8, out_written: *usize) error{WriteFailed}!void {
        var written: usize = 0;
        while (written < buffer.len) {
            const next_write = std.math.cast(u32, buffer.len - written) orelse std.math.maxInt(u32);
            var last_written: u32 = undefined;
            const result = std.os.windows.kernel32.WriteFile(hFile, buffer.ptr + written, next_write, &last_written, null);
            written += last_written; // WriteFile always sets last_written to 0 before doing anything
            if (result == 0) {
                out_written.* = written;
                return error.WriteFailed;
            }
        }
        out_written.* = written;
    }
    pub extern "kernel32" fn CreateFileA(
        lpFileName: ?[*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) std.os.windows.BOOL;
    pub extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
    pub extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpBuffer: ?[*]u8,
        nSize: u32,
    ) callconv(.winapi) u32;
};

const windows_signal_count = 32;
var windows_signal_mutex: std.Thread.Mutex = .{};
var windows_sigactions: [windows_signal_count]c.struct_sigaction =
    [_]c.struct_sigaction{std.mem.zeroes(c.struct_sigaction)} ** windows_signal_count;

fn windowsSignalIndex(sig: c_int) ?usize {
    if (sig <= 0 or sig >= windows_signal_count) return null;
    return @as(usize, @intCast(sig));
}

fn __zwindows_sigaction(
    sig: c_int,
    act: ?*const c.struct_sigaction,
    oact: ?*c.struct_sigaction,
) callconv(.c) c_int {
    if (builtin.os.tag != .windows) {
        errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }

    const index = windowsSignalIndex(sig) orelse {
        errno = c.EINVAL;
        return -1;
    };

    windows_signal_mutex.lock();
    defer windows_signal_mutex.unlock();

    if (oact) |out| out.* = windows_sigactions[index];
    if (act) |in| windows_sigactions[index] = in.*;
    return 0;
}

fn __zwindows_raise_signal(sig: c_int) callconv(.c) c_int {
    if (builtin.os.tag != .windows) {
        errno = errnoConst("ENOSYS", c.EINVAL);
        return -1;
    }

    const index = windowsSignalIndex(sig) orelse {
        errno = c.EINVAL;
        return -1;
    };

    var action: c.struct_sigaction = undefined;
    windows_signal_mutex.lock();
    action = windows_sigactions[index];
    windows_signal_mutex.unlock();

    if ((action.sa_flags & windows_signal_siginfo_bit) != 0) {
        if (action.sa_sigaction) |handler| {
            if (@intFromPtr(handler) == 1) return 0;
            handler(sig, null, null);
        }
        return 0;
    }

    if (action.sa_handler) |handler| {
        if (@intFromPtr(handler) == 1) return 0;
        handler(sig);
    }
    return 0;
}

comptime {
    if (builtin.target.ofmt == .coff) {
        @export(&__zwindows_sigaction, .{ .name = "__zwindows_sigaction" });
        @export(&__zwindows_raise_signal, .{ .name = "__zwindows_raise_signal" });
    } else {
        @export(&__zwindows_sigaction, .{ .name = "__zwindows_sigaction", .visibility = .hidden });
        @export(&__zwindows_raise_signal, .{ .name = "__zwindows_raise_signal", .visibility = .hidden });
    }
}

// --------------------------------------------------------------------------------
// errno
// --------------------------------------------------------------------------------
extern var errno: c_int;

// --------------------------------------------------------------------------------
// stdlib
// --------------------------------------------------------------------------------
export fn exit(status: c_int) callconv(.c) noreturn {
    trace.log("exit {}", .{status});

    {
        global.atexit_mutex.lock();
        defer global.atexit_mutex.unlock();
        global.atexit_started = true;
    }
    {
        var i = global.atexit_funcs.items.len;
        while (i != 0) : (i -= 1) {
            global.atexit_funcs.items[i - 1]();
        }
    }
    std.process.exit(@intCast(status));
}

const ExitFunc = switch (builtin.zig_backend) {
    .stage1 => fn () callconv(.c) void,
    else => *const fn () callconv(.c) void,
};

export fn atexit(func: ExitFunc) c_int {
    global.atexit_mutex.lock();
    defer global.atexit_mutex.unlock();

    if (global.atexit_started) {
        c.errno = c.EPERM;
        return -1;
    }
    global.atexit_funcs.append(global.gpa.allocator(), func) catch |e| switch (e) {
        error.OutOfMemory => {
            c.errno = c.ENOMEM;
            return -1;
        },
    };
    return 0;
}

export fn abort() callconv(.c) noreturn {
    trace.log("abort", .{});
    std.posix.abort();
}

export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    trace.log("getenv {f}", .{trace.fmtStr(name)});
    const key = std.mem.span(name);
    if (key.len == 0) return null;
    if (std.mem.indexOfScalar(u8, key, '=') != null) return null;
    if (builtin.os.tag == .wasi) return null;

    if (builtin.os.tag == .windows) {
        const required = windows.GetEnvironmentVariableA(name, null, 0);
        if (required == 0 or required > global.getenv_tmp.len) return null;
        const copied = windows.GetEnvironmentVariableA(name, &global.getenv_tmp, @intCast(global.getenv_tmp.len));
        if (copied == 0 or copied >= global.getenv_tmp.len) return null;
        global.getenv_tmp[copied] = 0;
        return @as([*:0]u8, @ptrCast(&global.getenv_tmp));
    }

    if (builtin.os.tag == .linux) {
        var file = std.fs.openFileAbsolute("/proc/self/environ", .{}) catch return null;
        defer file.close();
        var src: [32768]u8 = undefined;
        const src_len = file.readAll(&src) catch return null;

        var i: usize = 0;
        while (i < src_len) {
            const begin = i;
            while (i < src_len and src[i] != 0) : (i += 1) {}
            const line = src[begin..i];
            if (line.len > key.len and line[key.len] == '=' and std.mem.eql(u8, line[0..key.len], key)) {
                const value = line[key.len + 1 ..];
                if (value.len >= global.getenv_tmp.len) return null;
                @memcpy(global.getenv_tmp[0..value.len], value);
                global.getenv_tmp[value.len] = 0;
                return @as([*:0]u8, @ptrCast(&global.getenv_tmp));
            }
            i += 1;
        }
        return null;
    }

    if (builtin.os.tag.isDarwin()) {
        const envp = _NSGetEnviron().*;
        var i: usize = 0;
        while (envp[i]) |entry| : (i += 1) {
            const line = std.mem.span(entry);
            if (line.len > key.len and line[key.len] == '=' and std.mem.eql(u8, line[0..key.len], key)) {
                const value = line[key.len + 1 ..];
                if (value.len >= global.getenv_tmp.len) return null;
                @memcpy(global.getenv_tmp[0..value.len], value);
                global.getenv_tmp[value.len] = 0;
                return @as([*:0]u8, @ptrCast(&global.getenv_tmp));
            }
        }
    }

    return null;
}

fn signalName(sig: c_int) ?[]const u8 {
    if (@hasDecl(c, "SIGINT") and sig == c.SIGINT) return "Interrupt";
    if (@hasDecl(c, "SIGALRM") and sig == c.SIGALRM) return "Alarm clock";
    if (@hasDecl(c, "SIGABRT") and sig == c.SIGABRT) return "Aborted";
    if (@hasDecl(c, "SIGTERM") and sig == c.SIGTERM) return "Terminated";
    if (@hasDecl(c, "SIGSEGV") and sig == c.SIGSEGV) return "Segmentation fault";
    if (@hasDecl(c, "SIGILL") and sig == c.SIGILL) return "Illegal instruction";
    if (@hasDecl(c, "SIGFPE") and sig == c.SIGFPE) return "Floating point exception";
    return null;
}

export fn strsignal(sig: c_int) callconv(.c) [*:0]u8 {
    if (signalName(sig)) |name| {
        if (builtin.os.tag.isDarwin()) {
            const out = std.fmt.bufPrint(&global.tmp_strerror_buffer, "{s}: {}", .{ name, sig }) catch {
                global.tmp_strerror_buffer[0] = 0;
                return @as([*:0]u8, @ptrCast(&global.tmp_strerror_buffer));
            };
            global.tmp_strerror_buffer[out.len] = 0;
            return @as([*:0]u8, @ptrCast(&global.tmp_strerror_buffer));
        }
        @memcpy(global.tmp_strerror_buffer[0..name.len], name);
        global.tmp_strerror_buffer[name.len] = 0;
        return @as([*:0]u8, @ptrCast(&global.tmp_strerror_buffer));
    }

    const out = std.fmt.bufPrint(&global.tmp_strerror_buffer, "Unknown signal {}", .{sig}) catch {
        global.tmp_strerror_buffer[0] = 0;
        return @as([*:0]u8, @ptrCast(&global.tmp_strerror_buffer));
    };
    global.tmp_strerror_buffer[out.len] = 0;
    return @as([*:0]u8, @ptrCast(&global.tmp_strerror_buffer));
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

export fn system(string: ?[*:0]const u8) callconv(.c) c_int {
    trace.log("system {f}", .{trace.fmtStr(string)});
    if (builtin.os.tag == .windows) {
        if (string == null) {
            return if (winproc.hasShell()) 1 else 0;
        }

        var spawn_errno: c_int = 0;
        const process = winproc.spawnShell(string.?, null, null, null, false, &spawn_errno) orelse {
            errno = spawn_errno;
            return -1;
        };
        const status = winproc.waitProcessStatus(process);
        if (status == -1) return -1;
        return status;
    }
    if (builtin.os.tag == .wasi) {
        errno = c.ENOSYS;
        return -1;
    }
    if (builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) {
        errno = c.ENOSYS;
        return -1;
    }

    if (string == null) {
        if (builtin.os.tag.isDarwin()) {
            // Keep the Darwin shell probe inside this object. Calling into a
            // separate libc archive here regressed native Apple Silicon and also
            // left Linux test link steps with an unresolved `access` symbol.
            const rc = syscall(darwin_syscall.access, "/bin/sh", @as(usize, @intCast(c.X_OK)));
            return if (std.posix.errno(rc) == .SUCCESS) 1 else 0;
        }
        const rc = std.posix.system.access("/bin/sh", std.posix.X_OK);
        return if (std.posix.errno(rc) == .SUCCESS) 1 else 0;
    }

    const fork_rc = std.posix.system.fork();
    switch (std.posix.errno(fork_rc)) {
        .SUCCESS => {},
        else => |e| {
            errno = @intFromEnum(e);
            return -1;
        },
    }

    if (fork_rc == 0) {
        const shell_path: [*:0]const u8 = "/bin/sh";
        const command = string.?;
        var argv = [_:null]?[*:0]const u8{ shell_path, "-c", command, null };
        if (builtin.os.tag == .linux) {
            var env_buf: [32768]u8 = undefined;
            var env_ptrs = [_:null]?[*:0]u8{null} ** 1024;
            if (populateLinuxExecEnviron(&env_buf, &env_ptrs, env_ptrs.len)) {
                _ = std.posix.system.execve(shell_path, &argv, @ptrCast(&env_ptrs));
            }
        } else if (builtin.os.tag.isDarwin()) {
            _ = std.posix.system.execve(shell_path, &argv, @ptrCast(_NSGetEnviron().*));
        }
        const empty_envp = [_:null]?[*:0]const u8{null};
        _ = std.posix.system.execve(shell_path, &argv, @ptrCast(&empty_envp));
        std.posix.system.exit(127);
    }

    var status: if (builtin.os.tag.isDarwin()) c_int else u32 = 0;
    while (true) {
        const wait_rc = std.posix.system.waitpid(@as(std.posix.pid_t, @intCast(fork_rc)), &status, 0);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {
                if (builtin.os.tag.isDarwin()) return status;
                return @as(c_int, @bitCast(status));
            },
            .INTR => continue,
            else => |e| {
                errno = @intFromEnum(e);
                return -1;
            },
        }
    }
}

/// alloc_align is the maximum alignment needed for all types
/// since malloc is not type aware, it just aligns every allocation
/// to accomodate the maximum possible alignment that could be needed.
///
/// Shared malloc alignment requirement for this libc implementation.
const alloc_align = 16;

const alloc_metadata_len = std.mem.alignForward(usize, alloc_align, @sizeOf(usize));

pub export fn malloc(size: usize) callconv(.c) ?[*]align(alloc_align) u8 {
    trace.log("malloc {}", .{size});
    const alloc_size = if (size == 0) 1 else size;
    const full_len = alloc_metadata_len + alloc_size;
    const buf = global.gpa.allocator().alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alloc_align), full_len) catch |err| switch (err) {
        error.OutOfMemory => {
            trace.log("malloc return null", .{});
            return null;
        },
    };
    @as(*usize, @ptrCast(buf)).* = full_len;
    const result = @as([*]align(alloc_align) u8, @ptrFromInt(@intFromPtr(buf.ptr) + alloc_metadata_len));
    trace.log("malloc return {*}", .{result});
    return result;
}

fn getGpaBuf(ptr: [*]u8) []align(alloc_align) u8 {
    const start = @intFromPtr(ptr) - alloc_metadata_len;
    const len = @as(*usize, @ptrFromInt(start)).*;
    return @alignCast(@as([*]u8, @ptrFromInt(start))[0..len]);
}

export fn realloc(ptr: ?[*]align(alloc_align) u8, size: usize) callconv(.c) ?[*]align(alloc_align) u8 {
    trace.log("realloc {*} {}", .{ ptr, size });
    const gpa_buf = getGpaBuf(ptr orelse {
        const result = malloc(size);
        trace.log("realloc return {*} (from malloc)", .{result});
        return result;
    });
    if (size == 0) {
        global.gpa.allocator().free(gpa_buf);
        return null;
    }

    const gpa_size = alloc_metadata_len + size;
    if (global.gpa.allocator().rawResize(gpa_buf, .fromByteUnits(alloc_align), gpa_size, @returnAddress())) {
        @as(*usize, @ptrCast(gpa_buf.ptr)).* = gpa_size;
        trace.log("realloc return {*}", .{ptr});
        return ptr;
    }

    const new_buf = global.gpa.allocator().reallocAdvanced(
        gpa_buf,
        gpa_size,
        @returnAddress(),
    ) catch |e| switch (e) {
        error.OutOfMemory => {
            trace.log("realloc out-of-mem from {} to {}", .{ gpa_buf.len, gpa_size });
            return null;
        },
    };
    @as(*usize, @ptrCast(new_buf.ptr)).* = gpa_size;
    const result = @as([*]align(alloc_align) u8, @ptrFromInt(@intFromPtr(new_buf.ptr) + alloc_metadata_len));
    trace.log("realloc return {*}", .{result});
    return result;
}

export fn calloc(nmemb: usize, size: usize) callconv(.c) ?[*]align(alloc_align) u8 {
    const total = std.math.mul(usize, nmemb, size) catch {
        errno = c.ENOMEM;
        return null;
    };
    const ptr = malloc(total) orelse return null;
    @memset(ptr[0..total], 0);
    return ptr;
}

pub export fn free(ptr: ?[*]align(alloc_align) u8) callconv(.c) void {
    trace.log("free {*}", .{ptr});
    const p = ptr orelse return;
    global.gpa.allocator().free(getGpaBuf(p));
}

export fn srand(seed: c_uint) callconv(.c) void {
    trace.log("srand {}", .{seed});
    global.rand.seed(seed);
}

export fn rand() callconv(.c) c_int {
    return global.rand.random().intRangeAtMostBiased(c_int, 0, c.RAND_MAX);
}

export fn abs(j: c_int) callconv(.c) c_int {
    return if (j >= 0) j else -j;
}

export fn div(numer: c_int, denom: c_int) callconv(.c) c.div_t {
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

export fn labs(j: c_long) callconv(.c) c_long {
    return if (j >= 0) j else -j;
}

export fn ldiv(numer: c_long, denom: c_long) callconv(.c) c.ldiv_t {
    return .{
        .quot = @divTrunc(numer, denom),
        .rem = @rem(numer, denom),
    };
}

export fn atof(nptr: [*:0]const u8) callconv(.c) f64 {
    return strtod(nptr, null);
}

export fn atoi(nptr: [*:0]const u8) callconv(.c) c_int {
    // `atoi` intentionally follows the shared `strto` parsing path and does not
    // expose richer error reporting beyond the C return value contract.
    return strto(c_int, nptr, null, 10);
}

export fn atol(nptr: [*:0]const u8) callconv(.c) c_long {
    return strto(c_long, nptr, null, 10);
}

export fn mblen(s: ?[*:0]const u8, n: usize) callconv(.c) c_int {
    if (s == null) return 0;
    if (n == 0) return -1;
    if (s.?[0] == 0) return 0;
    return 1;
}

export fn mbtowc(pwc: ?*c.wchar_t, s: ?[*:0]const u8, n: usize) callconv(.c) c_int {
    if (s == null) return 0;
    if (n == 0) return -1;
    if (s.?[0] == 0) {
        if (pwc) |out| out.* = 0;
        return 0;
    }
    if (pwc) |out| out.* = @as(c.wchar_t, s.?[0]);
    return 1;
}

export fn wctomb(s: ?[*]u8, wchar: c.wchar_t) callconv(.c) c_int {
    if (s == null) return 0;
    if (wchar < 0 or wchar > 255) return -1;
    s.?[0] = @intCast(wchar);
    return 1;
}

export fn mbstowcs(pwcs: ?[*]c.wchar_t, s: [*:0]const u8, n: usize) callconv(.c) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (pwcs != null and i < n) pwcs.?[i] = @as(c.wchar_t, s[i]);
    }
    if (pwcs != null and i < n) pwcs.?[i] = 0;
    return i;
}

export fn wcstombs(s: ?[*]u8, pwcs: [*]const c.wchar_t, n: usize) callconv(.c) usize {
    var i: usize = 0;
    while (pwcs[i] != 0) : (i += 1) {
        if (pwcs[i] < 0 or pwcs[i] > 255) return std.math.maxInt(usize);
        if (s != null and i < n) s.?[i] = @intCast(pwcs[i]);
    }
    if (s != null and i < n) s.?[i] = 0;
    return i;
}

const SortCompareFn = *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;

fn sortElemPtr(base: [*]u8, index: usize, size: usize) [*]u8 {
    return base + index * size;
}

fn swapSortElems(base: [*]u8, lhs: usize, rhs: usize, size: usize) void {
    if (lhs == rhs) return;
    const lhs_ptr = sortElemPtr(base, lhs, size);
    const rhs_ptr = sortElemPtr(base, rhs, size);
    var i: usize = 0;
    while (i < size) : (i += 1) {
        std.mem.swap(u8, &lhs_ptr[i], &rhs_ptr[i]);
    }
}

fn qsortRange(base: [*]u8, lo: usize, hi: usize, size: usize, compar: SortCompareFn) void {
    if (hi - lo < 2) return;

    const pivot_index = lo + (hi - lo) / 2;
    const last = hi - 1;
    swapSortElems(base, pivot_index, last, size);

    var store = lo;
    var i = lo;
    while (i < last) : (i += 1) {
        if (compar(@ptrCast(sortElemPtr(base, i, size)), @ptrCast(sortElemPtr(base, last, size))) < 0) {
            swapSortElems(base, store, i, size);
            store += 1;
        }
    }
    swapSortElems(base, store, last, size);

    qsortRange(base, lo, store, size, compar);
    qsortRange(base, store + 1, hi, size, compar);
}

export fn bsearch(
    key: ?*const anyopaque,
    base: ?*const anyopaque,
    nmemb: usize,
    size: usize,
    compar: SortCompareFn,
) callconv(.c) ?*anyopaque {
    if (nmemb == 0 or size == 0 or base == null) return null;
    const bytes: [*]u8 = @ptrCast(@constCast(base.?));
    var lo: usize = 0;
    var hi: usize = nmemb;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_ptr: ?*anyopaque = @ptrCast(sortElemPtr(bytes, mid, size));
        const cmp = compar(key, @ptrCast(mid_ptr));
        if (cmp < 0) {
            hi = mid;
        } else if (cmp > 0) {
            lo = mid + 1;
        } else {
            return mid_ptr;
        }
    }
    return null;
}

export fn qsort(base: ?*anyopaque, nmemb: usize, size: usize, compar: SortCompareFn) callconv(.c) void {
    if (nmemb < 2 or size == 0 or base == null) return;
    qsortRange(@ptrCast(base.?), 0, nmemb, size, compar);
}

// --------------------------------------------------------------------------------
// string
// --------------------------------------------------------------------------------
export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    trace.log("strlen {f}", .{trace.fmtStr(s)});
    const result = std.mem.len(s);
    trace.log("strlen return {}", .{result});
    return result;
}
// Keep `strnlen` here for now even though some platforms expose it through POSIX.
fn strnlen(s: [*:0]const u8, max_len: usize) usize {
    trace.log("strnlen {*} max={}", .{ s, max_len });
    var i: usize = 0;
    while (i < max_len and s[i] != 0) : (i += 1) {}
    trace.log("strnlen return {}", .{i});
    return i;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    trace.log("strcmp {f} {f}", .{ trace.fmtStr(a), trace.fmtStr(b) });
    var a_next = a;
    var b_next = b;
    while (a_next[0] == b_next[0] and a_next[0] != 0) {
        a_next += 1;
        b_next += 1;
    }
    const result = @as(c_int, @intCast(a_next[0])) -| @as(c_int, @intCast(b_next[0]));
    trace.log("strcmp return {}", .{result});
    return result;
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    trace.log("strncmp {*} {*} n={}", .{ a, b, n });
    if (n == 0) return 0;
    var i: usize = 0;
    while (i < n and a[i] == b[i] and a[i] != 0) : (i += 1) {}
    if (i == n) return 0;
    return @as(c_int, @intCast(a[i])) -| @as(c_int, @intCast(b[i]));
}

export fn strcoll(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) c_int {
    // Locale-aware collation is not implemented yet; match "C" locale behavior.
    return strcmp(s1, s2);
}

export fn strxfrm(s1: ?[*]u8, s2: [*:0]const u8, n: usize) callconv(.c) usize {
    const len = strlen(s2);
    if (s1 != null and n != 0) {
        const copy_len = @min(len, n - 1);
        @memcpy(s1.?[0..copy_len], s2[0..copy_len]);
        s1.?[copy_len] = 0;
    }
    return len;
}

export fn strncasecmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ac = tolower(a[i]);
        const bc = tolower(b[i]);
        if (ac != bc or a[i] == 0 or b[i] == 0) {
            return ac -| bc;
        }
    }
    return 0;
}

export fn strchr(s: [*:0]const u8, char: c_int) callconv(.c) ?[*:0]const u8 {
    trace.log("strchr {f} c='{}'", .{ trace.fmtStr(s), char });
    var next = s;
    while (true) : (next += 1) {
        if (next[0] == char) return next;
        if (next[0] == 0) return null;
    }
}
export fn memchr(s: [*]const u8, char: c_int, n: usize) callconv(.c) ?[*]const u8 {
    trace.log("memchr {*} c='{}' n={}", .{ s, char, n });
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == n) return null;
        if (s[i] == char) return s + i;
    }
}

export fn strrchr(s: [*:0]const u8, char: c_int) callconv(.c) ?[*:0]const u8 {
    trace.log("strrchr {f} c='{}'", .{ trace.fmtStr(s), char });
    var next = s + strlen(s);
    while (true) {
        if (next[0] == char) return next;
        if (next == s) return null;
        next = next - 1;
    }
}

export fn strstr(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    trace.log("strstr {f} {f}", .{ trace.fmtStr(s1), trace.fmtStr(s2) });
    const s1_len = strlen(s1);
    const s2_len = strlen(s2);
    var i: usize = 0;
    while (i + s2_len <= s1_len) : (i += 1) {
        const search = s1 + i;
        if (0 == strncmp(search, s2, s2_len)) return search;
    }
    return null;
}

export fn strcpy(s1: [*]u8, s2: [*:0]const u8) callconv(.c) [*:0]u8 {
    trace.log("strcpy {*} {*}", .{ s1, s2 });
    @memcpy(s1[0 .. std.mem.len(s2) + 1], s2);
    return @as([*:0]u8, @ptrCast(s1));
}

export fn strcat(s1: [*]u8, s2: [*:0]const u8) callconv(.c) [*:0]u8 {
    trace.log("strcat {*} {f}", .{ s1, trace.fmtStr(s2) });
    var i: usize = 0;
    while (s1[i] != 0) : (i += 1) {}
    const len = std.mem.len(s2);
    @memcpy(s1[i .. i + len + 1], s2);
    return @as([*:0]u8, @ptrCast(s1));
}

// `strncpy` is part of the ISO C string API.
export fn strncpy(s1: [*]u8, s2: [*:0]const u8, n: usize) callconv(.c) [*]u8 {
    trace.log("strncpy {*} {f} n={}", .{ s1, trace.fmtStr(s2), n });
    const len = strnlen(s2, n);
    @memcpy(s1[0..len], s2);
    @memset(s1[len..][0 .. n - len], 0);
    return s1;
}

// NOTE: strlcpy and strlcat appear in some libc implementations (rejected by glibc though)
//       they don't appear to be a part of any standard.
//       not sure whether they should live in this library or a separate one
//       see https://lwn.net/Articles/507319/
export fn strlcpy(dst: ?[*]u8, src: [*:0]const u8, size: usize) callconv(.c) usize {
    trace.log("strncpy {*} {*} n={}", .{ dst, src, size });
    // C callers may pass a null destination when `size == 0`; that is valid as
    // long as the function only reports the source length and never dereferences
    // `dst`. Using a non-null Zig pointer here lets the backend assume the
    // pointer is always valid, which can turn this libc edge case into
    // target-specific crashes that only show up on some ABIs/backends.
    if (size == 0) return strlen(src);
    const out = dst.?;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == size) {
            if (size > 0)
                out[size - 1] = 0;
            return i + strlen(src + i);
        }
        out[i] = src[i];
        if (src[i] == 0) {
            return i;
        }
    }
}
export fn strlcat(dst: [*:0]u8, src: [*:0]const u8, size: usize) callconv(.c) usize {
    trace.log("strlcat {f} {f} n={}", .{ trace.fmtStr(dst), trace.fmtStr(src), size });
    const dst_len = strnlen(dst, size);
    if (dst_len == size) return dst_len + strlen(src);
    return dst_len + strlcpy(dst + dst_len, src, size - dst_len);
}

export fn strncat(s1: [*:0]u8, s2: [*:0]const u8, n: usize) callconv(.c) [*:0]u8 {
    trace.log("strncat {f} {f} n={}", .{ trace.fmtStr(s1), trace.fmtStr(s2), n });
    const dest = s1 + strlen(s1);
    var i: usize = 0;
    while (s2[i] != 0 and i < n) : (i += 1) {
        dest[i] = s2[i];
    }
    dest[i] = 0;
    return s1;
}

export fn strspn(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) usize {
    trace.log("strspn {f} {f}", .{ trace.fmtStr(s1), trace.fmtStr(s2) });
    var spn: usize = 0;
    while (true) : (spn += 1) {
        if (s1[spn] == 0 or null == strchr(s2, s1[spn])) return spn;
    }
}

export fn strcspn(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) usize {
    trace.log("strcspn {f} {f}", .{ trace.fmtStr(s1), trace.fmtStr(s2) });
    var spn: usize = 0;
    while (true) : (spn += 1) {
        if (s1[spn] == 0 or null != strchr(s2, s1[spn])) return spn;
    }
}

export fn strpbrk(s1: [*:0]const u8, s2: [*:0]const u8) callconv(.c) ?[*]const u8 {
    trace.log("strpbrk {f} {f}", .{ trace.fmtStr(s1), trace.fmtStr(s2) });
    var next = s1;
    while (true) : (next += 1) {
        if (next[0] == 0) return null;
        if (strchr(s2, next[0]) != null) return next;
    }
}

export fn strtok(s1: ?[*:0]u8, s2: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (s1 != null) {
        trace.log("strtok {f} {f}", .{ trace.fmtStr(s1.?), trace.fmtStr(s2) });
        global.strtok_ptr = s1;
    } else {
        trace.log("strtok NULL {f}", .{trace.fmtStr(s2)});
    }
    var next = global.strtok_ptr.?;
    next += strspn(next, s2);
    if (next[0] == 0) {
        return null;
    }
    const start = next;
    const end = start + 1 + strcspn(start + 1, s2);
    if (end[0] == 0) {
        global.strtok_ptr = end;
    } else {
        global.strtok_ptr = end + 1;
        end[0] = 0;
    }
    return start;
}

fn strto(comptime T: type, str: [*:0]const u8, optional_endptr: ?*[*:0]const u8, optional_base: c_int) T {
    var next = str;
    const no_digit_end = str;

    // skip whitespace
    while (isspace(next[0]) != 0) : (next += 1) {}
    const start = next;

    const sign: enum { pos, neg } = blk: {
        if (next[0] == '-') {
            next += 1;
            break :blk .neg;
        }
        if (next[0] == '+') next += 1;
        break :blk .pos;
    };

    const base = blk: {
        if (optional_base != 0) {
            if (optional_base > 36) {
                if (optional_endptr) |endptr| endptr.* = next;
                errno = c.EINVAL;
                return 0;
            }
            if (optional_base == 16 and next[0] == '0' and (next[1] == 'x' or next[1] == 'X')) {
                next += 2;
            }
            break :blk @as(u8, @intCast(optional_base));
        }
        if (next[0] == '0') {
            if (next[1] == 'x' or next[1] == 'X') {
                next += 2;
                break :blk 16;
            }
            next += 1;
            break :blk 8;
        }
        break :blk 10;
    };

    const digit_start = next;
    var x: T = 0;

    while (true) : (next += 1) {
        const ch = next[0];
        if (ch == 0) break;
        const digit = std.math.cast(T, std.fmt.charToDigit(ch, base) catch break) orelse {
            if (optional_endptr) |endptr| endptr.* = next;
            errno = c.ERANGE;
            return 0;
        };
        if (x != 0) x = std.math.mul(T, x, std.math.cast(T, base) orelse {
            errno = c.EINVAL;
            return 0;
        }) catch {
            if (optional_endptr) |endptr| endptr.* = next;
            errno = c.ERANGE;
            return switch (sign) {
                .neg => std.math.minInt(T),
                .pos => std.math.maxInt(T),
            };
        };
        x = switch (sign) {
            .pos => std.math.add(T, x, digit) catch {
                if (optional_endptr) |endptr| endptr.* = next + 1;
                errno = c.ERANGE;
                return switch (sign) {
                    .neg => std.math.minInt(T),
                    .pos => std.math.maxInt(T),
                };
            },
            .neg => std.math.sub(T, x, digit) catch {
                if (optional_endptr) |endptr| endptr.* = next + 1;
                errno = c.ERANGE;
                return switch (sign) {
                    .neg => std.math.minInt(T),
                    .pos => std.math.maxInt(T),
                };
            },
        };
    }

    if (next == digit_start) {
        if (builtin.os.tag.isDarwin()) {
            errno = c.EINVAL;
        }
        if (optional_endptr) |endptr| endptr.* = no_digit_end;
    } else {
        if (optional_endptr) |endptr| endptr.* = next;
        trace.log("strto str='{s}' result={}", .{ start[0 .. @intFromPtr(next) - @intFromPtr(start)], x });
    }
    return x;
}

export fn strtod(nptr: [*:0]const u8, endptr: ?*[*:0]const u8) callconv(.c) f64 {
    trace.log("strtod {f}", .{trace.fmtStr(nptr)});
    var i: usize = 0;
    while (true) : (i += 1) {
        switch (nptr[i]) {
            ' ', '\t', '\n', '\r', '\x0b', '\x0c' => {},
            else => break,
        }
    }
    const token_start = i;
    if (nptr[i] == '+' or nptr[i] == '-') i += 1;

    var saw_digit = false;
    while (std.ascii.isDigit(nptr[i])) : (i += 1) {
        saw_digit = true;
    }
    if (nptr[i] == '.') {
        i += 1;
        while (std.ascii.isDigit(nptr[i])) : (i += 1) {
            saw_digit = true;
        }
    }

    if (saw_digit and (nptr[i] == 'e' or nptr[i] == 'E')) {
        const exp_start = i;
        i += 1;
        if (nptr[i] == '+' or nptr[i] == '-') i += 1;
        var exp_digits: usize = 0;
        while (std.ascii.isDigit(nptr[i])) : (i += 1) {
            exp_digits += 1;
        }
        if (exp_digits == 0) i = exp_start;
    }

    if (!saw_digit or token_start == i) {
        if (endptr) |ep| ep.* = nptr;
        return 0;
    }

    if (endptr) |ep| ep.* = nptr + i;

    const result = std.fmt.parseFloat(f64, nptr[token_start..i]) catch |err| switch (err) {
        error.InvalidCharacter => {
            if (endptr) |ep| ep.* = nptr;
            return 0;
        },
    };
    return result;
}

export fn strtol(nptr: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_long {
    trace.log("strtol {f} endptr={*} base={}", .{ trace.fmtStr(nptr), endptr, base });
    return strto(c_long, nptr, endptr, base);
}

export fn strtoll(nptr: [*:0]const u8, endptr: ?*[*:0]const u8, base: c_int) callconv(.c) c_longlong {
    trace.log("strtoll {f} endptr={*} base={}", .{ trace.fmtStr(nptr), endptr, base });
    return strto(c_longlong, nptr, endptr, base);
}

export fn strtoul(nptr: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) callconv(.c) c_ulong {
    trace.log("strtoul {f} endptr={*} base={}", .{ trace.fmtStr(nptr), endptr, base });
    return strto(c_ulong, nptr, @ptrCast(endptr), base);
}

export fn strtoull(nptr: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) callconv(.c) c_ulonglong {
    trace.log("strtoull {f} endptr={*} base={}", .{ trace.fmtStr(nptr), endptr, base });
    return strto(c_ulonglong, nptr, @ptrCast(endptr), base);
}

fn errnoMessage(errnum: c_int, comptime name: []const u8, comptime msg: []const u8) ?[*:0]const u8 {
    if (@hasDecl(c, name) and errnum == @field(c, name)) {
        return @as([*:0]const u8, @ptrCast(msg));
    }
    return null;
}

export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    if (errnum == 0) return @as([*:0]const u8, @ptrCast("Success"));
    if (errnoMessage(errnum, "EPERM", "Operation not permitted")) |msg| return msg;
    if (errnoMessage(errnum, "ENOENT", "No such file or directory")) |msg| return msg;
    if (errnoMessage(errnum, "ESRCH", "No such process")) |msg| return msg;
    if (errnoMessage(errnum, "EINTR", "Interrupted function call")) |msg| return msg;
    if (errnoMessage(errnum, "EIO", "Input/output error")) |msg| return msg;
    if (errnoMessage(errnum, "ENXIO", "No such device or address")) |msg| return msg;
    if (errnoMessage(errnum, "E2BIG", "Argument list too long")) |msg| return msg;
    if (errnoMessage(errnum, "ENOEXEC", "Exec format error")) |msg| return msg;
    if (errnoMessage(errnum, "EBADF", "Bad file descriptor")) |msg| return msg;
    if (errnoMessage(errnum, "ECHILD", "No child processes")) |msg| return msg;
    if (errnoMessage(errnum, "EAGAIN", "Resource temporarily unavailable")) |msg| return msg;
    if (errnoMessage(errnum, "ENOMEM", "Not enough space")) |msg| return msg;
    if (errnoMessage(errnum, "EACCES", "Permission denied")) |msg| return msg;
    if (errnoMessage(errnum, "EFAULT", "Bad address")) |msg| return msg;
    if (errnoMessage(errnum, "EBUSY", "Device or resource busy")) |msg| return msg;
    if (errnoMessage(errnum, "EEXIST", "File exists")) |msg| return msg;
    if (errnoMessage(errnum, "ENODEV", "No such device")) |msg| return msg;
    if (errnoMessage(errnum, "ENOTDIR", "Not a directory")) |msg| return msg;
    if (errnoMessage(errnum, "EISDIR", "Is a directory")) |msg| return msg;
    if (errnoMessage(errnum, "EINVAL", "Invalid argument")) |msg| return msg;
    if (errnoMessage(errnum, "ENFILE", "Too many files open in system")) |msg| return msg;
    if (errnoMessage(errnum, "EMFILE", "Too many open files")) |msg| return msg;
    if (errnoMessage(errnum, "ENOTTY", "Inappropriate I/O control operation")) |msg| return msg;
    if (errnoMessage(errnum, "EFBIG", "File too large")) |msg| return msg;
    if (errnoMessage(errnum, "ENOSPC", "No space left on device")) |msg| return msg;
    if (errnoMessage(errnum, "ESPIPE", "Invalid seek")) |msg| return msg;
    if (errnoMessage(errnum, "EROFS", "Read-only file system")) |msg| return msg;
    if (errnoMessage(errnum, "EMLINK", "Too many links")) |msg| return msg;
    if (errnoMessage(errnum, "EPIPE", "Broken pipe")) |msg| return msg;
    if (errnoMessage(errnum, "EDOM", "Domain error")) |msg| return msg;
    if (errnoMessage(errnum, "ERANGE", "Result too large")) |msg| return msg;

    @memset(&global.tmp_strerror_buffer, 0);
    const out = std.fmt.bufPrint(&global.tmp_strerror_buffer, "{}", .{errnum}) catch {
        global.tmp_strerror_buffer[0] = '?';
        global.tmp_strerror_buffer[1] = 0;
        return @as([*:0]const u8, @ptrCast(&global.tmp_strerror_buffer));
    };
    if (out.len < global.tmp_strerror_buffer.len) {
        global.tmp_strerror_buffer[out.len] = 0;
    }
    return @as([*:0]const u8, @ptrCast(&global.tmp_strerror_buffer));
}

// --------------------------------------------------------------------------------
// signal
// --------------------------------------------------------------------------------
fn cSigactionHandlerType() type {
    return if (comptime @hasField(c.struct_sigaction, "sa_handler"))
        @TypeOf(@as(c.struct_sigaction, undefined).sa_handler)
    else
        @TypeOf(@as(c.struct_sigaction, undefined).unnamed_0.sa_handler);
}

fn cSigactionGetHandler(action: c.struct_sigaction) cSigactionHandlerType() {
    return if (comptime @hasField(c.struct_sigaction, "sa_handler"))
        action.sa_handler
    else
        action.unnamed_0.sa_handler;
}

fn cSigactionSetHandler(action: *c.struct_sigaction, handler: cSigactionHandlerType()) void {
    if (comptime @hasField(c.struct_sigaction, "sa_handler")) {
        action.sa_handler = handler;
    } else {
        action.unnamed_0.sa_handler = handler;
    }
}

fn _zsignalRaw(sig: c_int, func_ptr: usize) callconv(.c) usize {
    const sig_err = @as(usize, @bitCast(@as(isize, -1)));
    if (builtin.os.tag == .windows) {
        var action = std.mem.zeroes(c.struct_sigaction);
        cSigactionSetHandler(&action, @as(cSigactionHandlerType(), @ptrFromInt(func_ptr)));

        var old_action = std.mem.zeroes(c.struct_sigaction);
        if (__zwindows_sigaction(sig, &action, &old_action) != 0) {
            return sig_err;
        }
        return if (cSigactionGetHandler(old_action)) |h|
            @intFromPtr(h)
        else
            0;
    }
    if (sig < 0 or sig > std.math.maxInt(u6)) {
        errno = c.EINVAL;
        return sig_err;
    }
    if (builtin.os.tag.isDarwin()) {
        var action = std.mem.zeroes(c.struct_sigaction);
        cSigactionSetHandler(&action, @as(cSigactionHandlerType(), @ptrFromInt(func_ptr)));
        action.sa_flags = @as(c_int, @bitCast(@as(c_uint, @intCast(std.posix.SA.RESTART))));

        var old_action = std.mem.zeroes(c.struct_sigaction);
        if (c.sigaction(sig, &action, &old_action) != 0) {
            return sig_err;
        }
        return if (cSigactionGetHandler(old_action)) |h|
            @intFromPtr(h)
        else
            0;
    }
    var action = std.mem.zeroes(c.struct_sigaction);
    cSigactionSetHandler(&action, @as(cSigactionHandlerType(), @ptrFromInt(func_ptr)));
    action.sa_flags = @as(c_int, @bitCast(@as(c_uint, @intCast(std.posix.SA.RESTART))));

    var old_action: std.posix.Sigaction = undefined;
    switch (std.posix.errno(std.posix.system.sigaction(
        @as(u6, @intCast(sig)),
        @ptrCast(&action),
        &old_action,
    ))) {
        .SUCCESS => return @intFromPtr(old_action.handler.handler),
        else => |e| {
            errno = @intFromEnum(e);
            return sig_err;
        },
    }
}

comptime {
    if (builtin.target.ofmt == .coff) {
        @export(&_zsignalRaw, .{ .name = "_zsignalRaw" });
    } else {
        @export(&_zsignalRaw, .{ .name = "_zsignalRaw", .visibility = .hidden });
    }
}

// --------------------------------------------------------------------------------
// stdio
// --------------------------------------------------------------------------------
const global = struct {
    var rand: std.Random.DefaultPrng = undefined;
    var clock_start_ns: i128 = 0;
    var clock_started = false;

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .MutexType = std.Thread.Mutex,
    }){};

    var strtok_ptr: ?[*:0]u8 = undefined;

    const FileEntry = struct {
        reserved: bool = false,
        unread_valid: bool = false,
        unread_char: u8 = 0,
        file: c.FILE = .{
            .fd = if (builtin.os.tag == .windows) undefined else -1,
            .eof = 0,
            .errno = 0,
        },
    };
    const RemainderState = struct {
        bytes: std.ArrayListUnmanaged(u8) = .{},
        index: usize = 0,
    };
    const file_page_len = 64;
    const FilePage = [file_page_len]FileEntry;

    fn initStaticFilePage() FilePage {
        var page = [_]FileEntry{FileEntry{}} ** file_page_len;
        page[0].reserved = true;
        page[1].reserved = true;
        page[2].reserved = true;
        if (builtin.os.tag != .windows) {
            page[0].file.fd = std.posix.STDIN_FILENO;
            page[1].file.fd = std.posix.STDOUT_FILENO;
            page[2].file.fd = std.posix.STDERR_FILENO;
        }
        return page;
    }

    var static_file_page: FilePage = initStaticFilePage();
    var dynamic_file_pages: std.ArrayListUnmanaged(*FilePage) = .{};
    var file_pages_mutex = std.Thread.Mutex{};
    var remainder_states: std.AutoHashMapUnmanaged(usize, RemainderState) = .empty;
    var remainder_mutex = std.Thread.Mutex{};
    var tmpnam_counter: u32 = 0;
    var tmpfile_counter: u32 = 0;

    fn resetReservedEntry(entry: *FileEntry) *c.FILE {
        entry.file.eof = 0;
        entry.file.errno = 0;
        entry.unread_valid = false;
        entry.unread_char = 0;
        clearRemainder(&entry.file);
        return &entry.file;
    }

    fn reserveInPage(page: *FilePage) ?*c.FILE {
        for (page) |*entry| {
            if (entry.reserved) continue;
            entry.reserved = true;
            return resetReservedEntry(entry);
        }
        return null;
    }

    fn allocFilePage() ?*FilePage {
        const page = gpa.allocator().create(FilePage) catch return null;
        page.* = [_]FileEntry{FileEntry{}} ** file_page_len;
        return page;
    }

    fn reserveFile() ?*c.FILE {
        file_pages_mutex.lock();
        defer file_pages_mutex.unlock();

        if (reserveInPage(&static_file_page)) |file| return file;
        for (dynamic_file_pages.items) |page| {
            if (reserveInPage(page)) |file| return file;
        }

        const new_page = allocFilePage() orelse return null;
        dynamic_file_pages.append(gpa.allocator(), new_page) catch {
            gpa.allocator().destroy(new_page);
            return null;
        };
        return reserveInPage(new_page);
    }

    fn releaseFile(file: *c.FILE) void {
        const entry: *FileEntry = @fieldParentPtr("file", file);
        file_pages_mutex.lock();
        defer file_pages_mutex.unlock();
        entry.unread_valid = false;
        entry.unread_char = 0;
        removeRemainder(file);
        file.eof = 0;
        file.errno = 0;
        if (builtin.os.tag == .windows) {
            file.fd = null;
        } else {
            file.fd = -1;
        }
        entry.reserved = false;
    }

    fn clearRemainder(file: *c.FILE) void {
        remainder_mutex.lock();
        defer remainder_mutex.unlock();
        if (remainder_states.getPtr(@intFromPtr(file))) |state| {
            state.bytes.clearRetainingCapacity();
            state.index = 0;
        }
    }

    fn removeRemainder(file: *c.FILE) void {
        remainder_mutex.lock();
        defer remainder_mutex.unlock();
        if (remainder_states.fetchRemove(@intFromPtr(file))) |kv| {
            var state = kv.value;
            state.bytes.deinit(gpa.allocator());
        }
    }

    fn hasRemainder(file: *c.FILE) bool {
        remainder_mutex.lock();
        defer remainder_mutex.unlock();
        if (remainder_states.getPtr(@intFromPtr(file))) |state| {
            return state.index < state.bytes.items.len;
        }
        return false;
    }

    fn readRemainder(file: *c.FILE, dest: []u8) usize {
        if (dest.len == 0) return 0;
        remainder_mutex.lock();
        defer remainder_mutex.unlock();
        const state = remainder_states.getPtr(@intFromPtr(file)) orelse return 0;
        const pending = state.bytes.items[state.index..];
        if (pending.len == 0) return 0;
        const copy_len = @min(dest.len, pending.len);
        @memcpy(dest[0..copy_len], pending[0..copy_len]);
        state.index += copy_len;
        if (state.index == state.bytes.items.len) {
            state.bytes.clearRetainingCapacity();
            state.index = 0;
        }
        return copy_len;
    }

    fn replaceRemainder(file: *c.FILE, bytes: []const u8) !void {
        remainder_mutex.lock();
        defer remainder_mutex.unlock();
        const gop = try remainder_states.getOrPut(gpa.allocator(), @intFromPtr(file));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.bytes.clearRetainingCapacity();
        gop.value_ptr.index = 0;
        try gop.value_ptr.bytes.appendSlice(gpa.allocator(), bytes);
    }

    // Scratch storage for short strerror/strsignal-style formatting.
    var tmp_strerror_buffer: [30]u8 = undefined;
    var getenv_tmp: [32768:0]u8 = [_:0]u8{0} ** 32768;
    var current_locale = [_:0]u8{'C'};
    var gmtime_tm: c.tm = std.mem.zeroes(c.tm);
    var localtime_tm: c.tm = std.mem.zeroes(c.tm);
    var asctime_buf: [26:0]u8 = [_:0]u8{0} ** 26;

    var atexit_mutex = std.Thread.Mutex{};
    var atexit_started = false;
    // `atexit` storage is contiguous today; chunking would only be a future
    // allocation/perf improvement.
    var atexit_funcs: std.ArrayListUnmanaged(ExitFunc) = .{};

    var decimal_point = [_:0]u8{'.'};
    var thousands_sep = [_:0]u8{};
    var grouping = [_:0]u8{};
    var int_curr_symbol = [_:0]u8{};
    var currency_symbol = [_:0]u8{};
    var mon_decimal_point = [_:0]u8{};
    var mon_thousands_sep = [_:0]u8{};
    var mon_grouping = [_:0]u8{};
    var positive_sign = [_:0]u8{};
    var negative_sign = [_:0]u8{};
    var localeconv = c.struct_lconv{
        .decimal_point = &decimal_point,
        .thousands_sep = &thousands_sep,
        .grouping = &grouping,
        .int_curr_symbol = &int_curr_symbol,
        .currency_symbol = &currency_symbol,
        .mon_decimal_point = &mon_decimal_point,
        .mon_thousands_sep = &mon_thousands_sep,
        .mon_grouping = &mon_grouping,
        .positive_sign = &positive_sign,
        .negative_sign = &negative_sign,
        .int_frac_digits = c.CHAR_MAX,
        .frac_digits = c.CHAR_MAX,
        .p_cs_precedes = c.CHAR_MAX,
        .p_sep_by_space = c.CHAR_MAX,
        .n_cs_precedes = c.CHAR_MAX,
        .n_sep_by_space = c.CHAR_MAX,
        .p_sign_posn = c.CHAR_MAX,
        .n_sign_posn = c.CHAR_MAX,
    };
};

export const stdin: *c.FILE = &global.static_file_page[0].file;
export const stdout: *c.FILE = &global.static_file_page[1].file;
export const stderr: *c.FILE = &global.static_file_page[2].file;

fn entryFromFile(stream: *c.FILE) *global.FileEntry {
    return @fieldParentPtr("file", stream);
}

fn closePosixFd(fd: c_int) bool {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return true,
        else => |e| {
            errno = @intFromEnum(e);
            return false;
        },
    }
}

// used by posix.zig
export fn __zreserveFile() callconv(.c) ?*c.FILE {
    return global.reserveFile();
}

export fn remove(filename: [*:0]const u8) callconv(.c) c_int {
    trace.log("remove {f}", .{trace.fmtStr(filename)});
    if (builtin.os.tag.isDarwin()) {
        return zunlinkCompat(filename);
    }
    std.posix.unlinkZ(filename) catch |err| {
        errno = switch (err) {
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

export fn rename(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    trace.log("rename {f} {f}", .{ trace.fmtStr(old), trace.fmtStr(new) });
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.rename, old, new);
        if (rc == -1) {
            errno = __error().*;
            return -1;
        }
        return 0;
    }
    std.posix.renameZ(old, new) catch |err| {
        errno = switch (err) {
            error.AccessDenied => c.EACCES,
            error.PermissionDenied => c.EPERM,
            error.FileBusy => errnoConst("EBUSY", c.EINVAL),
            error.DiskQuota => errnoConst("EDQUOT", errnoConst("ENOSPC", c.ENOMEM)),
            error.IsDir => errnoConst("EISDIR", c.EINVAL),
            error.SymLinkLoop => errnoConst("ELOOP", c.EINVAL),
            error.LinkQuotaExceeded => errnoConst("EMLINK", c.EINVAL),
            error.NameTooLong => errnoConst("ENAMETOOLONG", c.EINVAL),
            error.FileNotFound => c.ENOENT,
            error.NotDir => errnoConst("ENOTDIR", c.EINVAL),
            error.SystemResources => c.ENOMEM,
            error.NoSpaceLeft => errnoConst("ENOSPC", c.ENOMEM),
            error.PathAlreadyExists => c.EEXIST,
            error.ReadOnlyFileSystem => errnoConst("EROFS", c.EPERM),
            error.RenameAcrossMountPoints => errnoConst("EXDEV", c.EINVAL),
            error.InvalidUtf8, error.InvalidWtf8, error.BadPathName => c.EINVAL,
            error.NoDevice => errnoConst("ENODEV", c.EINVAL),
            error.SharingViolation, error.PipeBusy => errnoConst("EBUSY", c.EINVAL),
            error.NetworkNotFound => c.ENOENT,
            error.AntivirusInterference => c.EACCES,
            else => errnoConst("EIO", c.EINVAL),
        };
        return -1;
    };
    return 0;
}

export fn getchar() callconv(.c) c_int {
    return getc(stdin);
}

export fn getc(stream: *c.FILE) callconv(.c) c_int {
    trace.log("getc {*}", .{stream});
    var buf: [1]u8 = undefined;
    const len = _fread_buf(&buf, 1, stream);
    if (len == 0) {
        trace.log("getc return EOF, errno={}", .{stream.errno});
        return c.EOF;
    }
    std.debug.assert(len == 1);
    trace.log("getc return {}", .{buf[0]});
    return buf[0];
}

// NOTE: this causes a bug in the Zig compiler, but it shouldn't
//       for now I'm working around it by making a wrapper function
//comptime {
//    (&getc, .{ .name = "fgetc" });
//}
export fn fgetc(stream: *c.FILE) callconv(.c) c_int {
    return getc(stream);
}

export fn ungetc(char: c_int, stream: *c.FILE) callconv(.c) c_int {
    if (char == c.EOF) return c.EOF;
    const entry = entryFromFile(stream);
    if (entry.unread_valid) {
        errno = c.EINVAL;
        stream.errno = errno;
        return c.EOF;
    }
    entry.unread_valid = true;
    entry.unread_char = @as(u8, @intCast(char & 0xff));
    stream.eof = 0;
    stream.errno = 0;
    return char & 0xff;
}

export fn _fread_buf(ptr: [*]u8, size: usize, stream: *c.FILE) callconv(.c) usize {
    if (size == 0) return 0;
    var prefilled: usize = 0;
    const entry = entryFromFile(stream);
    if (entry.unread_valid) {
        ptr[0] = entry.unread_char;
        entry.unread_valid = false;
        prefilled = 1;
        if (size == 1) return 1;
    }
    if (prefilled < size) {
        prefilled += global.readRemainder(stream, ptr[prefilled..size]);
        if (prefilled == size) return prefilled;
    }
    const remaining = size - prefilled;
    const dest = ptr + prefilled;

    if (builtin.os.tag == .windows) {
        const actual_read_len = @as(u32, @intCast(@min(@as(u32, std.math.maxInt(u32)), remaining)));
        while (true) {
            var amt_read: u32 = undefined;
            if (std.os.windows.kernel32.ReadFile(stream.fd.?, dest, actual_read_len, &amt_read, null) == 0) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    .OPERATION_ABORTED => continue,
                    .BROKEN_PIPE => return prefilled,
                    .HANDLE_EOF => return prefilled,
                    else => |err| {
                        stream.errno = @intFromEnum(err);
                        errno = stream.errno;
                        return prefilled;
                    },
                }
            }
            if (amt_read == 0) stream.eof = 1;
            return prefilled + @as(usize, @intCast(amt_read));
        }
    }

    // Prevents EINVAL.
    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    const adjusted_len = @min(max_count, remaining);

    const rc = std.posix.system.read(stream.fd, dest, adjusted_len);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            if (rc == 0) stream.eof = 1;
            return prefilled + @as(usize, @intCast(rc));
        },
        else => |e| {
            errno = @intFromEnum(e);
            return prefilled;
        },
    }
}

export fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *c.FILE) callconv(.c) usize {
    const entry = entryFromFile(stream);
    if (size == 0 or nmemb == 0) return 0;
    if (stream.eof != 0 and !entry.unread_valid and !global.hasRemainder(stream)) {
        return 0;
    }
    const total = size * nmemb;
    const result = _fread_buf(ptr, total, stream);
    if (result == 0) return 0;
    if (result == total) return nmemb;
    const remainder_len = result % size;
    if (remainder_len == 0) return result / size;
    const aligned_len = result - remainder_len;
    global.replaceRemainder(stream, ptr[aligned_len..result]) catch {
        stream.errno = c.ENOMEM;
        errno = c.ENOMEM;
        return aligned_len / size;
    };
    return aligned_len / size;
}

export fn feof(stream: *c.FILE) callconv(.c) c_int {
    return stream.eof;
}

fn fopenImpl(
    filename: [*:0]const u8,
    mode: [*:0]const u8,
    force_largefile: bool,
    comptime func_name: []const u8,
) ?*c.FILE {
    trace.log("{s} {f} mode={f}", .{ func_name, trace.fmtStr(filename), trace.fmtStr(mode) });
    const ModeKind = enum { read, write, append };
    const ParsedMode = struct {
        kind: ModeKind,
        plus: bool = false,
        excl: bool = false,
    };
    const parsed: ParsedMode = blk: {
        const mode_slice = std.mem.span(mode);
        if (mode_slice.len == 0) {
            errno = c.EINVAL;
            return null;
        }
        var p = ParsedMode{
            .kind = switch (mode_slice[0]) {
                'r' => .read,
                'w' => .write,
                'a' => .append,
                else => {
                    errno = c.EINVAL;
                    return null;
                },
            },
        };
        for (mode_slice[1..]) |mode_char| {
            switch (mode_char) {
                'b', 't', 'e' => {},
                '+' => p.plus = true,
                'x' => p.excl = true,
                else => {
                    errno = c.EINVAL;
                    return null;
                },
            }
        }
        if (p.excl and p.kind == .read) {
            errno = c.EINVAL;
            return null;
        }
        break :blk p;
    };

    if (builtin.os.tag == .windows) {
        const create_disposition: u32 = switch (parsed.kind) {
            .read => std.os.windows.OPEN_EXISTING,
            .write => if (parsed.excl) std.os.windows.CREATE_NEW else std.os.windows.CREATE_ALWAYS,
            .append => if (parsed.excl) std.os.windows.CREATE_NEW else std.os.windows.OPEN_ALWAYS,
        };
        var access: u32 = 0;
        if (parsed.plus or parsed.kind == .read) {
            access |= std.os.windows.GENERIC_READ;
        }
        if (parsed.plus or parsed.kind != .read) {
            access |= std.os.windows.GENERIC_WRITE;
        }
        const fd = windows.CreateFileA(
            filename,
            access,
            std.os.windows.FILE_SHARE_DELETE |
                std.os.windows.FILE_SHARE_READ |
                std.os.windows.FILE_SHARE_WRITE,
            null,
            create_disposition,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (fd == std.os.windows.INVALID_HANDLE_VALUE) {
            errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return null;
        }
        if (parsed.kind == .append) {
            std.os.windows.SetFilePointerEx_END(fd.?, 0) catch {
                _ = windows.CloseHandle(fd.?);
                errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
                return null;
            };
        }
        const file = global.reserveFile() orelse {
            _ = windows.CloseHandle(fd.?);
            errno = c.ENOMEM;
            return null;
        };
        const stream_flags: c_int = switch (parsed.kind) {
            .read => if (parsed.plus) c.O_RDWR else c.O_RDONLY,
            .write, .append => if (parsed.plus) c.O_RDWR else c.O_WRONLY,
        } | (if (parsed.kind == .append) c.O_APPEND else 0);
        _ = winfd.allocHandleFlags(fd.?, stream_flags, 0) catch {
            global.releaseFile(file);
            _ = windows.CloseHandle(fd.?);
            errno = errnoConst("EMFILE", c.ENOMEM);
            return null;
        };
        file.fd = fd;
        file.eof = 0;
        return file;
    }

    var flags: c_int = switch (parsed.kind) {
        .read => if (parsed.plus) c.O_RDWR else c.O_RDONLY,
        .write, .append => if (parsed.plus) c.O_RDWR else c.O_WRONLY,
    };
    if (parsed.kind != .read) flags |= c.O_CREAT;
    if (parsed.kind == .write) flags |= c.O_TRUNC;
    if (parsed.kind == .append) flags |= c.O_APPEND;
    if (parsed.excl) flags |= c.O_EXCL;
    if (force_largefile and @hasDecl(c, "O_LARGEFILE")) {
        flags |= c.O_LARGEFILE;
    }
    const fd = zopenCompat(filename, flags, 0o666);
    if (fd < 0) {
        trace.log("{s} return null (errno={})", .{ func_name, errno });
        return null;
    }
    const file = global.reserveFile() orelse {
        _ = std.posix.system.close(fd);
        errno = c.ENOMEM;
        return null;
    };
    file.fd = fd;
    file.eof = 0;
    return file;
}

pub export fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    return fopenImpl(filename, mode, false, "fopen");
}

pub export fn fopen64(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    return fopenImpl(filename, mode, true, "fopen64");
}

export fn freopen(filename: [*:0]const u8, mode: [*:0]const u8, stream: *c.FILE) callconv(.c) ?*c.FILE {
    const new_stream = fopenImpl(filename, mode, false, "freopen") orelse return null;
    if (builtin.os.tag == .windows) {
        if (winfd.fdFromHandle(stream.fd.?)) |fd| {
            const close_errno = winfd.closeFd(fd);
            if (close_errno != 0) {
                _ = fclose(new_stream);
                errno = close_errno;
                return null;
            }
        } else if (windows.CloseHandle(stream.fd.?) == 0) {
            _ = fclose(new_stream);
            errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return null;
        }
    } else {
        if (!closePosixFd(stream.fd)) {
            const close_errno = errno;
            _ = fclose(new_stream);
            errno = close_errno;
            stream.errno = errno;
            return null;
        }
    }
    stream.fd = new_stream.fd;
    stream.eof = 0;
    stream.errno = 0;
    entryFromFile(stream).unread_valid = false;
    global.clearRemainder(stream);
    entryFromFile(new_stream).unread_valid = false;
    if (new_stream != stream) global.releaseFile(new_stream);
    return stream;
}

export fn fclose(stream: *c.FILE) callconv(.c) c_int {
    trace.log("fclose {*}", .{stream});
    if (builtin.os.tag == .windows) {
        if (winfd.fdFromHandle(stream.fd.?)) |fd| {
            const close_errno = winfd.closeFd(fd);
            if (close_errno != 0) {
                errno = close_errno;
                return c.EOF;
            }
        } else if (windows.CloseHandle(stream.fd.?) == 0) {
            errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return c.EOF;
        }
    } else {
        if (!closePosixFd(stream.fd)) {
            stream.errno = errno;
            return c.EOF;
        }
    }
    global.releaseFile(stream);
    return 0;
}

export fn fseek(stream: *c.FILE, offset: c_long, whence: c_int) callconv(.c) c_int {
    trace.log("fseek {*} offset={} whence={}", .{ stream, offset, whence });
    const fd: std.posix.fd_t = if (builtin.os.tag == .windows) stream.fd.? else stream.fd;
    const seek_result = switch (whence) {
        c.SEEK_SET => blk: {
            if (offset < 0) {
                errno = c.EINVAL;
                stream.errno = errno;
                return -1;
            }
            break :blk std.posix.lseek_SET(fd, @as(u64, @intCast(offset)));
        },
        c.SEEK_CUR => std.posix.lseek_CUR(fd, @as(i64, @intCast(offset))),
        c.SEEK_END => std.posix.lseek_END(fd, @as(i64, @intCast(offset))),
        else => {
            errno = c.EINVAL;
            stream.errno = errno;
            return -1;
        },
    };
    seek_result catch |e| {
        errno = switch (e) {
            error.Unseekable => errnoConst("ESPIPE", c.EINVAL),
            error.AccessDenied => c.EACCES,
            else => errnoConst("EIO", c.EINVAL),
        };
        stream.errno = errno;
        return -1;
    };
    stream.eof = 0;
    stream.errno = 0;
    entryFromFile(stream).unread_valid = false;
    global.clearRemainder(stream);
    return 0;
}

export fn ftell(stream: *c.FILE) callconv(.c) c_long {
    const fd: std.posix.fd_t = if (builtin.os.tag == .windows) stream.fd.? else stream.fd;
    var offset = std.posix.lseek_CUR_get(fd) catch |e| {
        errno = switch (e) {
            error.Unseekable => errnoConst("ESPIPE", c.EINVAL),
            error.AccessDenied => c.EACCES,
            else => errnoConst("EIO", c.EINVAL),
        };
        stream.errno = errno;
        return -1;
    };
    if (entryFromFile(stream).unread_valid and offset > 0) {
        offset -= 1;
    }
    if (offset > std.math.maxInt(c_long)) {
        errno = errnoConst("EOVERFLOW", c.ERANGE);
        stream.errno = errno;
        return -1;
    }
    stream.errno = 0;
    return @as(c_long, @intCast(offset));
}

export fn fgetpos(stream: *c.FILE, pos: *c.fpos_t) callconv(.c) c_int {
    const offset = ftell(stream);
    if (offset < 0) return -1;
    pos.* = @intCast(offset);
    return 0;
}

export fn fsetpos(stream: *c.FILE, pos: *const c.fpos_t) callconv(.c) c_int {
    if (pos.* > std.math.maxInt(c_long)) {
        errno = errnoConst("EOVERFLOW", c.ERANGE);
        stream.errno = errno;
        return -1;
    }
    return fseek(stream, @intCast(pos.*), c.SEEK_SET);
}

export fn rewind(stream: *c.FILE) callconv(.c) void {
    trace.log("rewind {*}", .{stream});
    if (0 == fseek(stream, 0, c.SEEK_SET)) {
        stream.eof = 0;
        stream.errno = 0;
    }
}

comptime {
    @export(&fputc, .{ .name = "putc" });
}

export fn fputc(character: c_int, stream: *c.FILE) callconv(.c) c_int {
    trace.log("fputc {} stream={*}", .{ character, stream });
    const buf = [_]u8{@as(u8, @intCast(0xff & character))};
    if (_fwrite_buf(&buf, 1, stream) == 1) return character;
    if (stream.errno == 0) stream.errno = errnoConst("EIO", c.EINVAL);
    return c.EOF;
}

// NOTE: this is not apart of libc
export fn _fwrite_buf(ptr: [*]const u8, size: usize, stream: *c.FILE) callconv(.c) usize {
    if (builtin.os.tag == .windows) {
        var written: usize = undefined;
        windows.writeAll(stream.fd.?, ptr[0..size], &written) catch {
            stream.errno = @intFromEnum(std.os.windows.kernel32.GetLastError());
        };
        return written;
    }
    const written = std.posix.system.write(stream.fd, ptr, size);
    switch (std.posix.errno(written)) {
        .SUCCESS => {
            if (written != size) {
                stream.errno = @intFromEnum(std.posix.E.IO);
            }
            return @as(usize, @intCast(written));
        },
        else => |e| {
            stream.errno = @intFromEnum(e);
            return 0;
        },
    }
}

const FormatLength = enum {
    none,
    short,
    char,
    long,
    long_long,
    size,
};

const FormatWriter = union(enum) {
    stream: *c.FILE,
    bounded: struct {
        buf: [*]u8,
        len: usize,
        overflow: bool = false,
    },
    unbounded: struct {
        buf: [*]u8,
    },

    fn write(self: *FormatWriter, bytes: []const u8) usize {
        if (bytes.len == 0) return 0;
        return switch (self.*) {
            .stream => |stream| _fwrite_buf(bytes.ptr, bytes.len, stream),
            .bounded => |*bounded| blk: {
                if (!bounded.overflow) {
                    if (bytes.len > bounded.len) {
                        bounded.overflow = true;
                    } else {
                        @memcpy(bounded.buf[0..bytes.len], bytes);
                        bounded.buf += bytes.len;
                        bounded.len -= bytes.len;
                    }
                }
                break :blk bytes.len;
            },
            .unbounded => |*unbounded| blk: {
                @memcpy(unbounded.buf[0..bytes.len], bytes);
                unbounded.buf += bytes.len;
                break :blk bytes.len;
            },
        };
    }
};

fn stringPrintLen(s: [*:0]const u8, precision: usize) usize {
    var len: usize = 0;
    while (s[len] != 0 and len < precision) : (len += 1) {}
    return len;
}

fn isFormatFlag(ch: u8) bool {
    return ch == '-' or ch == '+' or ch == ' ' or ch == '#' or ch == '0';
}

fn vaArgWindows(args: *c.va_list, comptime T: type) T {
    if (comptime builtin.cpu.arch != .x86_64) {
        return @cVaArg(args, T);
    }
    if (comptime @sizeOf(T) > 8) {
        @compileError("Unsupported Win64 va_arg size");
    }

    const addr = @intFromPtr(args.*);
    if (addr == 0) unreachable;

    const src: [*]const u8 = @ptrFromInt(addr);
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), src[0..@sizeOf(T)]);
    args.* = @ptrFromInt(addr + 8);
    return value;
}

const VaListCursor = if (builtin.os.tag == .windows) *c.va_list else *anyopaque;

inline fn vaArgCompat(args: VaListCursor, comptime T: type) T {
    if (comptime builtin.os.tag == .windows) {
        return vaArgWindows(args, T);
    }
    return @cVaArg(@as(*std.builtin.VaList, @ptrCast(@alignCast(args))), T);
}

fn vformat(out_written: *usize, writer: *FormatWriter, fmt: [*:0]const u8, args: VaListCursor) callconv(.c) bool {
    out_written.* = 0;
    const fmt_slice = std.mem.span(fmt);
    var i: usize = 0;

    while (true) {
        const next_percent = std.mem.indexOfScalarPos(u8, fmt_slice, i, '%') orelse break;
        if (next_percent > i) {
            const part = fmt_slice[i..next_percent];
            const written = writer.write(part);
            out_written.* += written;
            if (written != part.len) return false;
        }
        i = next_percent + 1;
        if (i >= fmt_slice.len) return false;

        if (isFormatFlag(fmt_slice[i])) return false;

        if (fmt_slice[i] == '*') {
            return false;
        } else if (fmt_slice[i] >= '0' and fmt_slice[i] <= '9') {
            return false;
        }

        const precision_none: i32 = -1;
        var precision: i32 = precision_none;
        if (fmt_slice[i] == '.') {
            i += 1;
            if (i >= fmt_slice.len) return false;
            if (fmt_slice[i] == '*') {
                precision = vaArgCompat(args, c_int);
                i += 1;
            } else if (fmt_slice[i] >= '0' and fmt_slice[i] <= '9') {
                return false;
            } else {
                return false;
            }
            if (i >= fmt_slice.len) return false;
        }

        var spec_length: FormatLength = .none;
        if (fmt_slice[i] == 'h') {
            if (i + 1 < fmt_slice.len and fmt_slice[i + 1] == 'h') {
                spec_length = .char;
                i += 2;
            } else {
                spec_length = .short;
                i += 1;
            }
            if (i >= fmt_slice.len) return false;
        } else if (fmt_slice[i] == 'l') {
            if (i + 1 < fmt_slice.len and fmt_slice[i + 1] == 'l') {
                spec_length = .long_long;
                i += 2;
            } else {
                spec_length = .long;
                i += 1;
            }
            if (i >= fmt_slice.len) return false;
        } else if (fmt_slice[i] == 'z') {
            spec_length = .size;
            i += 1;
            if (i >= fmt_slice.len) return false;
        }

        switch (fmt_slice[i]) {
            's' => {
                if (spec_length != .none) return false;
                const maybe_s = vaArgCompat(args, ?[*:0]const u8);
                const s = maybe_s orelse "(null)";
                const len = if (precision == precision_none or precision < 0)
                    std.mem.len(s)
                else
                    stringPrintLen(s, @intCast(precision));
                const written = writer.write(s[0..len]);
                out_written.* += written;
                if (written != len) return false;
            },
            'c' => {
                if (spec_length != .none or precision != precision_none) return false;
                const value = vaArgCompat(args, c_int);
                const ch = [_]u8{@intCast(value & 0xff)};
                const written = writer.write(&ch);
                out_written.* += written;
                if (written != 1) return false;
            },
            'd' => {
                if (precision != precision_none) return false;
                var buf: [100]u8 = undefined;
                const len = switch (spec_length) {
                    .none => formatIntCompat(&buf, vaArgCompat(args, c_int), 10),
                    .short => formatIntCompat(&buf, @as(i16, @intCast(vaArgCompat(args, c_int))), 10),
                    .char => formatIntCompat(&buf, @as(i8, @intCast(vaArgCompat(args, c_int))), 10),
                    .long => formatIntCompat(&buf, vaArgCompat(args, c_long), 10),
                    .long_long => formatIntCompat(&buf, vaArgCompat(args, c_longlong), 10),
                    .size => formatIntCompat(&buf, vaArgCompat(args, isize), 10),
                };
                const written = writer.write(buf[0..len]);
                out_written.* += written;
                if (written != len) return false;
            },
            'u', 'x' => |specifier| {
                if (precision != precision_none) return false;
                const base: u8 = if (specifier == 'u') 10 else 16;
                var buf: [100]u8 = undefined;
                const len = switch (spec_length) {
                    .none => formatIntCompat(&buf, vaArgCompat(args, c_uint), base),
                    .short => formatIntCompat(&buf, @as(u16, @intCast(vaArgCompat(args, c_uint))), base),
                    .char => formatIntCompat(&buf, @as(u8, @intCast(vaArgCompat(args, c_uint))), base),
                    .long => formatIntCompat(&buf, vaArgCompat(args, c_ulong), base),
                    .long_long => formatIntCompat(&buf, vaArgCompat(args, c_ulonglong), base),
                    .size => formatIntCompat(&buf, vaArgCompat(args, usize), base),
                };
                const written = writer.write(buf[0..len]);
                out_written.* += written;
                if (written != len) return false;
            },
            'p' => {
                if (spec_length != .none or precision != precision_none) return false;
                const ptr_value = @intFromPtr(vaArgCompat(args, ?*const anyopaque) orelse @as(?*const anyopaque, null));
                var buf: [2 + (@sizeOf(usize) * 2)]u8 = undefined;
                buf[0] = '0';
                buf[1] = 'x';
                const hex_len = formatIntCompat(buf[2..], ptr_value, 16);
                const total_len = 2 + hex_len;
                const written = writer.write(buf[0..total_len]);
                out_written.* += written;
                if (written != total_len) return false;
            },
            else => return false,
        }

        i += 1;
    }

    if (i < fmt_slice.len) {
        const rest = fmt_slice[i..];
        const written = writer.write(rest);
        out_written.* += written;
        if (written != rest.len) return false;
    }
    return true;
}

fn vformatWithCVaListPtr(
    out_written: *usize,
    writer: *FormatWriter,
    format: [*:0]const u8,
    arg: *c.va_list,
) bool {
    if (comptime builtin.os.tag == .windows) {
        return vformat(out_written, writer, format, arg);
    }
    const va_list_info = @typeInfo(c.va_list);
    const va_list_tag = comptime std.meta.activeTag(va_list_info);
    if (comptime va_list_tag == .array) {
        const info = va_list_info.array;
        if (info.len != 1) @compileError("unsupported C va_list array shape");
        return vformat(out_written, writer, format, @ptrCast(&arg[0]));
    }
    if (comptime va_list_tag == .pointer) {
        const va = arg.*;
        return vformat(out_written, writer, format, @ptrCast(va));
    }
    if (comptime va_list_tag == .@"struct") {
        return vformat(out_written, writer, format, @ptrCast(arg));
    }
    @compileError("unsupported C va_list representation");
}

fn _zvfprintf(stream: *c.FILE, format: [*:0]const u8, arg: *c.va_list) callconv(.c) c_int {
    var writer = FormatWriter{ .stream = stream };
    var written: usize = 0;
    const ok = vformatWithCVaListPtr(&written, &writer, format, arg);
    if (ok) {
        return @intCast(written);
    } else {
        stream.errno = c.errno;
        return -1;
    }
}

fn _zvsnprintf(s: [*]u8, n: usize, format: [*:0]const u8, arg: *c.va_list) callconv(.c) c_int {
    var writer = FormatWriter{ .bounded = .{
        .buf = s,
        .len = n,
    } };
    var written: usize = 0;
    const ok = vformatWithCVaListPtr(&written, &writer, format, arg);
    std.debug.assert(ok);
    if (written < n) s[written] = 0;
    return @intCast(written);
}

fn _zvsprintf(s: [*]u8, format: [*:0]const u8, arg: *c.va_list) callconv(.c) c_int {
    var writer = FormatWriter{ .unbounded = .{
        .buf = s,
    } };
    var written: usize = 0;
    const ok = vformatWithCVaListPtr(&written, &writer, format, arg);
    std.debug.assert(ok);
    s[written] = 0;
    return @intCast(written);
}

const ScanKind = enum {
    end,
    token,
    string,
    hex,
    scan_error,
};

const ScanMod = enum {
    none,
    long,
};

const Scan = union(ScanKind) {
    end: void,
    token: struct {
        start: usize,
        limit: usize,
    },
    string: struct {
        width: i32,
    },
    hex: struct {
        mod: ScanMod,
    },
    scan_error: void,
};

const FixedReader = struct {
    buf: [*:0]const u8,

    fn read(self: *FixedReader) u8 {
        const ch = self.buf[0];
        if (ch != 0) self.buf += 1;
        return ch;
    }
};

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '\x0b' or ch == '\x0c';
}

fn parseWidth(fmt: []const u8, index: *usize) i32 {
    if (index.* >= fmt.len) return -1;
    const ch = fmt[index.*];
    if (ch < '1' or ch > '9') return -1;
    var width: i32 = ch - '0';
    while (true) {
        index.* += 1;
        if (index.* >= fmt.len) break;
        const cch = fmt[index.*];
        if (cch < '0' or cch > '9') break;
        width *= 10;
        width += cch - '0';
    }
    return width;
}

fn hexValue(ch: u8) i32 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    return -1;
}

fn getNextScan(fmt: []const u8, index: *usize) Scan {
    while (index.* < fmt.len and isWhitespace(fmt[index.*])) : (index.* += 1) {}
    if (index.* >= fmt.len) return .{ .end = {} };

    const first = fmt[index.*];
    if (first == '%' or first == '=') {
        index.* += 1;
        if (index.* >= fmt.len) return .{ .scan_error = {} };

        var mod: ScanMod = .none;
        if (fmt[index.*] == 'l') {
            index.* += 1;
            if (index.* < fmt.len and fmt[index.*] == 'l') {
                return .{ .scan_error = {} };
            }
            mod = .long;
        }

        const width = parseWidth(fmt, index);
        if (index.* >= fmt.len) return .{ .scan_error = {} };
        const cch = fmt[index.*];
        index.* += 1;
        if (cch == 's') {
            if (mod != .none) return .{ .scan_error = {} };
            return .{ .string = .{ .width = width } };
        }
        if (cch == 'x' or cch == 'X') {
            if (width != -1) return .{ .scan_error = {} };
            return .{ .hex = .{ .mod = mod } };
        }
        return .{ .scan_error = {} };
    }

    const start = index.*;
    while (index.* < fmt.len) : (index.* += 1) {
        const cch = fmt[index.*];
        if (cch == '%' or cch == '=' or isWhitespace(cch)) break;
    }
    return .{ .token = .{
        .start = start,
        .limit = index.*,
    } };
}

fn vscan(reader: *FixedReader, fmt: [*:0]const u8, args: VaListCursor) callconv(.c) c_int {
    const fmt_slice = std.mem.span(fmt);
    var fmt_index: usize = 0;
    var scan_count: c_int = 0;

    while (true) {
        const scan = getNextScan(fmt_slice, &fmt_index);
        switch (scan) {
            .end => return scan_count,
            .scan_error => return -1,
            .token => |token| {
                var ch: u8 = 0;
                while (true) {
                    ch = reader.read();
                    if (!isWhitespace(ch)) break;
                }
                var pos = token.start;
                while (true) {
                    if (fmt_slice[pos] != ch) return if (scan_count == 0) -1 else scan_count;
                    pos += 1;
                    if (pos >= token.limit) break;
                    ch = reader.read();
                }
            },
            .string => |scan_string| {
                var ch: u8 = 0;
                while (true) {
                    ch = reader.read();
                    if (!isWhitespace(ch)) break;
                }

                const out = vaArgCompat(args, [*]u8);
                var total_read: usize = 0;
                while (ch != 0) {
                    out[total_read] = ch;
                    total_read += 1;
                    if (scan_string.width != -1 and total_read >= @as(usize, @intCast(scan_string.width))) break;
                    ch = reader.read();
                    if (isWhitespace(ch)) break;
                }
                if (total_read == 0) return if (scan_count == 0) -1 else scan_count;
                out[total_read] = 0;
                scan_count += 1;
            },
            .hex => |scan_hex| {
                var ch: u8 = 0;
                while (true) {
                    ch = reader.read();
                    if (!isWhitespace(ch)) break;
                }

                var read_at_least_one = false;
                switch (scan_hex.mod) {
                    .none => {
                        var value: c_int = 0;
                        while (true) {
                            const v = hexValue(ch);
                            if (v == -1) break;
                            read_at_least_one = true;
                            value *%= 16;
                            value +%= @as(c_int, @intCast(v));
                            ch = reader.read();
                        }
                        if (!read_at_least_one) return if (scan_count == 0) -1 else scan_count;
                        const out = vaArgCompat(args, *c_int);
                        out.* = value;
                    },
                    .long => {
                        var value: c_long = 0;
                        while (true) {
                            const v = hexValue(ch);
                            if (v == -1) break;
                            read_at_least_one = true;
                            value *%= 16;
                            value +%= @as(c_long, @intCast(v));
                            ch = reader.read();
                        }
                        if (!read_at_least_one) return if (scan_count == 0) -1 else scan_count;
                        const out = vaArgCompat(args, *c_long);
                        out.* = value;
                    },
                }
                scan_count += 1;
            },
        }
    }
}

fn vscanWithCVaListPtr(reader: *FixedReader, fmt: [*:0]const u8, arg: *c.va_list) c_int {
    if (comptime builtin.os.tag == .windows) {
        return vscan(reader, fmt, arg);
    }
    const va_list_info = @typeInfo(c.va_list);
    const va_list_tag = comptime std.meta.activeTag(va_list_info);
    if (comptime va_list_tag == .array) {
        const info = va_list_info.array;
        if (info.len != 1) @compileError("unsupported C va_list array shape");
        return vscan(reader, fmt, @ptrCast(&arg[0]));
    }
    if (comptime va_list_tag == .pointer) {
        return vscan(reader, fmt, @ptrCast(arg.*));
    }
    if (comptime va_list_tag == .@"struct") {
        return vscan(reader, fmt, @ptrCast(arg));
    }
    @compileError("unsupported C va_list representation");
}

fn _zvsscanf(s: [*:0]const u8, fmt: [*:0]const u8, arg: *c.va_list) callconv(.c) c_int {
    var reader = FixedReader{ .buf = s };
    return vscanWithCVaListPtr(&reader, fmt, arg);
}

comptime {
    if (builtin.target.ofmt == .coff) {
        @export(&_zvfprintf, .{ .name = "_zvfprintf" });
        @export(&_zvsnprintf, .{ .name = "_zvsnprintf" });
        @export(&_zvsprintf, .{ .name = "_zvsprintf" });
        @export(&_zvsscanf, .{ .name = "_zvsscanf" });
    } else {
        @export(&_zvfprintf, .{ .name = "_zvfprintf", .visibility = .hidden });
        @export(&_zvsnprintf, .{ .name = "_zvsnprintf", .visibility = .hidden });
        @export(&_zvsprintf, .{ .name = "_zvsprintf", .visibility = .hidden });
        @export(&_zvsscanf, .{ .name = "_zvsscanf", .visibility = .hidden });
    }
}

export fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *c.FILE) callconv(.c) usize {
    trace.log("fwrite {*} size={} n={} stream={*}", .{ ptr, size, nmemb, stream });
    if (size == 0 or nmemb == 0) return 0;
    const total = size * nmemb;
    const result = _fwrite_buf(ptr, total, stream);
    if (result == total) return nmemb;
    return result / size;
}

export fn fflush(stream: ?*c.FILE) callconv(.c) c_int {
    trace.log("fflush {*}", .{stream});
    return 0; // no-op since there's no buffering right now
}

export fn putchar(ch: c_int) callconv(.c) c_int {
    trace.log("putchar {}", .{ch});
    const buf = [_]u8{@as(u8, @intCast(ch & 0xff))};
    return if (1 == _fwrite_buf(&buf, 1, stdout)) buf[0] else c.EOF;
}

export fn puts(s: [*:0]const u8) callconv(.c) c_int {
    trace.log("puts {f}", .{trace.fmtStr(s)});
    const len = std.mem.len(s);
    if (_fwrite_buf(s, len, stdout) != len) return c.EOF;
    const newline = [_]u8{'\n'};
    if (_fwrite_buf(&newline, 1, stdout) != 1) return c.EOF;
    return 1;
}

export fn fputs(s: [*:0]const u8, stream: *c.FILE) callconv(.c) c_int {
    trace.log("fputs {f} stream={*}", .{ trace.fmtStr(s), stream });
    const len = std.mem.len(s);
    const written = _fwrite_buf(s, len, stream);
    return if (written == len) 1 else c.EOF;
}

export fn fgets(s: [*]u8, n: c_int, stream: *c.FILE) callconv(.c) ?[*]u8 {
    if (stream.eof != 0) return null;

    // This is intentionally simple and currently reads byte-at-a-time.
    var total_read: usize = 0;
    while (true) : (total_read += 1) {
        if (total_read + 1 >= n) {
            s[total_read] = 0;
            return s;
        }
        stream.errno = 0;
        const result = getc(stream);
        if (result == c.EOF) {
            if (stream.errno == 0) {
                stream.eof = 1;
                if (total_read > 0) {
                    s[total_read] = 0;
                    return s;
                }
            }
            return null;
        }
        s[total_read] = @as(u8, @intCast(result));
        if (s[total_read] == '\n') {
            s[total_read + 1] = 0;
            return s;
        }
    }
}

export fn gets(s: [*]u8) callconv(.c) ?[*]u8 {
    var len: usize = 0;
    while (true) {
        const ch = getchar();
        if (ch == c.EOF) {
            if (len == 0) return null;
            break;
        }
        if (ch == '\n') break;
        s[len] = @intCast(ch);
        len += 1;
    }
    s[len] = 0;
    return s;
}

export fn tmpfile() callconv(.c) ?*c.FILE {
    if (builtin.os.tag == .windows) {
        var temp_buf: [std.os.windows.MAX_PATH:0]u8 = undefined;
        const temp_len = windows.GetTempPathA(temp_buf.len, &temp_buf);
        if (temp_len == 0 or temp_len >= temp_buf.len) {
            errno = winfd.errnoFromWin32(std.os.windows.kernel32.GetLastError());
            return null;
        }
        var attempt_windows: usize = 0;
        while (attempt_windows < 1024) : (attempt_windows += 1) {
            const id = @atomicRmw(u32, &global.tmpfile_counter, .Add, 1, .seq_cst);
            var name_buf: [std.os.windows.MAX_PATH:0]u8 = undefined;
            const name = std.fmt.bufPrint(
                name_buf[0 .. name_buf.len - 1],
                "{s}tmpfile-{x:0>8}.tmp",
                .{ temp_buf[0..temp_len], id },
            ) catch unreachable;
            name_buf[name.len] = 0;

            const fd = windows.CreateFileA(
                &name_buf,
                std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
                std.os.windows.FILE_SHARE_DELETE |
                    std.os.windows.FILE_SHARE_READ |
                    std.os.windows.FILE_SHARE_WRITE,
                null,
                std.os.windows.CREATE_NEW,
                std.os.windows.FILE_ATTRIBUTE_TEMPORARY |
                    std.os.windows.FILE_FLAG_DELETE_ON_CLOSE,
                null,
            );
            if (fd != std.os.windows.INVALID_HANDLE_VALUE) {
                const file = global.reserveFile() orelse {
                    _ = windows.CloseHandle(fd.?);
                    errno = c.ENOMEM;
                    return null;
                };
                _ = winfd.allocHandleFlags(fd.?, c.O_RDWR, 0) catch {
                    global.releaseFile(file);
                    _ = windows.CloseHandle(fd.?);
                    errno = errnoConst("EMFILE", c.ENOMEM);
                    return null;
                };
                file.fd = fd;
                file.eof = 0;
                file.errno = 0;
                return file;
            }
            const win_err = std.os.windows.kernel32.GetLastError();
            if (win_err == .FILE_EXISTS or win_err == .ALREADY_EXISTS) continue;
            errno = winfd.errnoFromWin32(win_err);
            return null;
        }
        errno = c.EEXIST;
        return null;
    }
    var attempt: usize = 0;
    while (attempt < 1024) : (attempt += 1) {
        const id = @atomicRmw(u32, &global.tmpfile_counter, .Add, 1, .seq_cst);
        var name_buf: [32:0]u8 = undefined;
        const name = std.fmt.bufPrint(name_buf[0 .. name_buf.len - 1], "tmpfile-{x:0>8}", .{id}) catch unreachable;
        name_buf[name.len] = 0;

        var flags: c_int = c.O_RDWR | c.O_CREAT | c.O_EXCL;
        if (@hasDecl(c, "O_LARGEFILE")) flags |= c.O_LARGEFILE;

        const fd = zopenCompat(&name_buf, flags, 0o600);
        if (fd >= 0) {
            _ = zunlinkCompat(&name_buf);
            const file = global.reserveFile() orelse {
                _ = std.posix.system.close(fd);
                errno = c.ENOMEM;
                return null;
            };
            file.fd = fd;
            file.eof = 0;
            file.errno = 0;
            return file;
        }
        if (errno == c.EEXIST) continue;
        return null;
    }
    errno = c.EEXIST;
    return null;
}

export fn tmpnam(s: [*]u8) callconv(.c) [*]u8 {
    const id = @atomicRmw(u32, &global.tmpnam_counter, .Add, 1, .seq_cst);
    var tmp: [c.L_tmpnam]u8 = [_]u8{0} ** c.L_tmpnam;
    const name = std.fmt.bufPrint(tmp[0 .. tmp.len - 1], "zltmp{x:0>8}", .{id}) catch unreachable;
    @memcpy(s[0..name.len], name);
    s[name.len] = 0;
    return s;
}

export fn clearerr(stream: *c.FILE) callconv(.c) void {
    trace.log("clearerr {*}", .{stream});
    stream.eof = 0;
    stream.errno = 0;
}

export fn setvbuf(stream: *c.FILE, buf: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int {
    _ = stream;
    _ = buf;
    _ = size;
    if (mode != c._IOFBF and mode != c._IOLBF and mode != c._IONBF) {
        errno = c.EINVAL;
        return -1;
    }
    return 0;
}

export fn setbuf(stream: *c.FILE, buf: ?[*]u8) callconv(.c) void {
    _ = setvbuf(stream, buf, if (buf == null) c._IONBF else c._IOFBF, if (buf == null) 0 else c.BUFSIZ);
}

export fn ferror(stream: *c.FILE) callconv(.c) c_int {
    trace.log("ferror {*} return {}", .{ stream, stream.errno });
    return stream.errno;
}

export fn perror(s: [*:0]const u8) callconv(.c) void {
    trace.log("perror {f}", .{trace.fmtStr(s)});
    const prefix_len = std.mem.len(s);
    if (prefix_len != 0) {
        _ = _fwrite_buf(s, prefix_len, stderr);
        _ = _fwrite_buf(": ", 2, stderr);
    }
    const message = std.mem.span(strerror(errno));
    _ = _fwrite_buf(message.ptr, message.len, stderr);
    _ = _fwrite_buf("\n", 1, stderr);
}

// NOTE: this is not a libc function, it's exported so it can be used
//       by vformat in libc.c
// buf must be at least 100 bytes
export fn _formatCInt(buf: [*]u8, value: c_int, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}
export fn _formatCUint(buf: [*]u8, value: c_uint, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}
export fn _formatCLong(buf: [*]u8, value: c_long, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}
export fn _formatCUlong(buf: [*]u8, value: c_ulong, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}
export fn _formatCLonglong(buf: [*]u8, value: c_longlong, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}
export fn _formatCUlonglong(buf: [*]u8, value: c_ulonglong, base: u8) callconv(.c) usize {
    return formatIntCompat(buf[0..100], value, base);
}

fn formatIntCompat(buf: []u8, value: anytype, base: u8) usize {
    const out = switch (base) {
        2 => std.fmt.bufPrint(buf, "{b}", .{value}) catch unreachable,
        8 => std.fmt.bufPrint(buf, "{o}", .{value}) catch unreachable,
        10 => std.fmt.bufPrint(buf, "{}", .{value}) catch unreachable,
        16 => std.fmt.bufPrint(buf, "{x}", .{value}) catch unreachable,
        else => std.fmt.bufPrint(buf, "{}", .{value}) catch unreachable,
    };
    return out.len;
}

// --------------------------------------------------------------------------------
// math
// --------------------------------------------------------------------------------
export fn acos(x: f64) callconv(.c) f64 {
    return std.math.acos(x);
}

export fn asin(x: f64) callconv(.c) f64 {
    return std.math.asin(x);
}

export fn atan(x: f64) callconv(.c) f64 {
    return std.math.atan(x);
}

export fn atan2(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}

const trig_pi = 3.14159265358979323846264338327950288;
const trig_tau = 2.0 * trig_pi;
const trig_half_pi = trig_pi / 2.0;
const trig_ln2 = 0.69314718055994530941723212145817657;
const trig_inv_ln2 = 1.44269504088896340735992468100189214;
const trig_ln10 = 2.30258509299404568401799145468436421;

fn reduceTrigAngle(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return std.math.nan(f64);
    var y = x - floorCompat(x / trig_tau) * trig_tau;
    if (y > trig_pi) y -= trig_tau;
    if (y < -trig_pi) y += trig_tau;
    return y;
}

fn sinApprox(x: f64) f64 {
    var y = reduceTrigAngle(x);
    if (y > trig_half_pi) {
        y = trig_pi - y;
    } else if (y < -trig_half_pi) {
        y = -trig_pi - y;
    }
    const y2 = y * y;
    const poly = (((((-1.0 / 39916800.0) * y2 + 1.0 / 362880.0) * y2 - 1.0 / 5040.0) * y2 + 1.0 / 120.0) * y2 - 1.0 / 6.0) * y2 + 1.0;
    return poly * y;
}

fn cosApprox(x: f64) f64 {
    var y = reduceTrigAngle(x);
    if (y > trig_half_pi) {
        y = trig_pi - y;
        return -cosApprox(y);
    }
    if (y < -trig_half_pi) {
        y = -trig_pi - y;
        return -cosApprox(y);
    }
    const y2 = y * y;
    return (((((-1.0 / 3628800.0) * y2 + 1.0 / 40320.0) * y2 - 1.0 / 720.0) * y2 + 1.0 / 24.0) * y2 - 1.0 / 2.0) * y2 + 1.0;
}

export fn cos(x: f64) callconv(.c) f64 {
    return cosApprox(x);
}

export fn sin(x: f64) callconv(.c) f64 {
    return sinApprox(x);
}

export fn cosh(x: f64) callconv(.c) f64 {
    const pos = expApprox(x);
    const neg = expApprox(-x);
    return (pos + neg) / 2.0;
}

export fn sinh(x: f64) callconv(.c) f64 {
    const pos = expApprox(x);
    const neg = expApprox(-x);
    return (pos - neg) / 2.0;
}

export fn tan(x: f64) callconv(.c) f64 {
    return sinApprox(x) / cosApprox(x);
}

export fn tanh(x: f64) callconv(.c) f64 {
    if (std.math.isNan(x)) return std.math.nan(f64);
    if (x >= 20.0) return 1.0;
    if (x <= -20.0) return -1.0;
    const pos = expApprox(x);
    const neg = expApprox(-x);
    return (pos - neg) / (pos + neg);
}

export fn exp(x: f64) callconv(.c) f64 {
    return expApprox(x);
}

export fn frexp(value: f32, out_exp: *c_int) callconv(.c) f64 {
    const result = std.math.frexp(value);
    out_exp.* = result.exponent;
    return result.significand;
}

export fn ldexp(x: f64, exponent: c_int) callconv(.c) f64 {
    return std.math.ldexp(x, @as(i32, @intCast(exponent)));
}

export fn pow(x: f64, y: f64) callconv(.c) f64 {
    if (y == 0.0) return 1.0;
    if (x == 0.0) return if (y > 0.0) 0.0 else std.math.inf(f64);
    const truncated = @trunc(y);
    if (y == truncated and truncated >= @as(f64, @floatFromInt(std.math.minInt(i63))) and truncated <= @as(f64, @floatFromInt(std.math.maxInt(i63)))) {
        var base: f64 = x;
        var exponent: i64 = @intFromFloat(truncated);
        var result: f64 = 1.0;
        const invert = exponent < 0;
        if (invert) exponent = -exponent;
        while (exponent != 0) : (exponent >>= 1) {
            if ((exponent & 1) != 0) result *= base;
            base *= base;
        }
        return if (invert) 1.0 / result else result;
    }
    if (x < 0.0) return std.math.nan(f64);
    return expApprox(y * logApprox(x));
}

export fn log(x: f64) callconv(.c) f64 {
    return logApprox(x);
}

export fn log10(x: f64) callconv(.c) f64 {
    return logApprox(x) / trig_ln10;
}

export fn modf(value: f64, iptr: *f64) callconv(.c) f64 {
    const parts = std.math.modf(value);
    iptr.* = parts.ipart;
    return parts.fpart;
}

export fn sqrt(x: f64) callconv(.c) f64 {
    return @sqrt(x);
}

export fn ceil(x: f64) callconv(.c) f64 {
    return ceilCompat(x);
}

export fn fabs(x: f64) callconv(.c) f64 {
    return @abs(x);
}

export fn floor(x: f64) callconv(.c) f64 {
    return floorCompat(x);
}

export fn fmod(x: f64, y: f64) callconv(.c) f64 {
    if (y == 0.0) return std.math.nan(f64);
    return x - @trunc(x / y) * y;
}

export fn log2(x: f64) callconv(.c) f64 {
    return logApprox(x) / trig_ln2;
}

export fn log2f(x: f32) callconv(.c) f32 {
    return @floatCast(logApprox(x) / trig_ln2);
}

export fn log2l(x: c_longdouble) callconv(.c) c_longdouble {
    return @floatCast(logApprox(@floatCast(x)) / trig_ln2);
}

fn expApprox(x: f64) f64 {
    if (std.math.isNan(x)) return std.math.nan(f64);
    if (x == std.math.inf(f64)) return std.math.inf(f64);
    if (x == -std.math.inf(f64)) return 0.0;
    if (x > 709.0) return std.math.inf(f64);
    if (x < -745.0) return 0.0;

    const n = @as(i32, @intFromFloat(floorCompat(x * trig_inv_ln2 + 0.5)));
    const r = x - @as(f64, @floatFromInt(n)) * trig_ln2;
    const r2 = r * r;
    const r3 = r2 * r;
    const r4 = r3 * r;
    const r5 = r4 * r;
    const r6 = r5 * r;
    const r7 = r6 * r;
    const r8 = r7 * r;
    const r9 = r8 * r;
    const r10 = r9 * r;
    const r11 = r10 * r;
    const r12 = r11 * r;
    const poly = 1.0 +
        r +
        r2 * 0.5 +
        r3 * (1.0 / 6.0) +
        r4 * (1.0 / 24.0) +
        r5 * (1.0 / 120.0) +
        r6 * (1.0 / 720.0) +
        r7 * (1.0 / 5040.0) +
        r8 * (1.0 / 40320.0) +
        r9 * (1.0 / 362880.0) +
        r10 * (1.0 / 3628800.0) +
        r11 * (1.0 / 39916800.0) +
        r12 * (1.0 / 479001600.0);
    return std.math.ldexp(poly, n);
}

fn logApprox(x: f64) f64 {
    if (std.math.isNan(x)) return std.math.nan(f64);
    if (x == 0.0) return -std.math.inf(f64);
    if (x < 0.0) return std.math.nan(f64);
    if (x == std.math.inf(f64)) return std.math.inf(f64);

    const parts = std.math.frexp(x);
    var mantissa = parts.significand;
    var exponent = parts.exponent;
    if (mantissa < 0.7071067811865475244) {
        mantissa *= 2.0;
        exponent -= 1;
    }

    const y = (mantissa - 1.0) / (mantissa + 1.0);
    const y2 = y * y;
    var series = y;
    var term = y;
    inline for ([_]f64{ 3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0, 17.0, 19.0, 21.0, 23.0, 25.0 }) |denom| {
        term *= y2;
        series += term / denom;
    }
    return 2.0 * series + @as(f64, @floatFromInt(exponent)) * trig_ln2;
}

fn floorCompat(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0.0) return x;
    const truncated = @trunc(x);
    return if (truncated > x) truncated - 1.0 else truncated;
}

fn ceilCompat(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0.0) return x;
    const truncated = @trunc(x);
    return if (truncated < x) truncated + 1.0 else truncated;
}

// --------------------------------------------------------------------------------
// locale
// --------------------------------------------------------------------------------
export fn setlocale(category: c_int, locale: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    _ = category;
    if (locale == null) {
        return @as([*:0]u8, @ptrCast(&global.current_locale));
    }
    const requested = std.mem.span(locale.?);
    if (requested.len == 0 or std.mem.eql(u8, requested, "C") or std.mem.eql(u8, requested, "POSIX")) {
        global.current_locale[0] = 'C';
        global.current_locale[1] = 0;
        return @as([*:0]u8, @ptrCast(&global.current_locale));
    }
    errno = c.EINVAL;
    return null;
}

export fn localeconv() callconv(.c) *c.lconv {
    trace.log("localeconv", .{});
    return &global.localeconv;
}

// --------------------------------------------------------------------------------
// time
// --------------------------------------------------------------------------------
export fn clock() callconv(.c) c.clock_t {
    const now_ns = std.time.nanoTimestamp();
    if (!global.clock_started) {
        global.clock_start_ns = now_ns;
        global.clock_started = true;
    }
    const elapsed_ns = now_ns - global.clock_start_ns;
    const ticks_per_second: i128 = c.CLOCKS_PER_SEC;
    const ns_per_tick: i128 = @divFloor(std.time.ns_per_s, ticks_per_second);
    const ticks = @divFloor(elapsed_ns, ns_per_tick);
    if (ticks < 0 or ticks > std.math.maxInt(c.clock_t)) {
        errno = errnoConst("EOVERFLOW", c.ERANGE);
        return -1;
    }
    return @as(c.clock_t, @intCast(ticks));
}

export fn difftime(time1: c.time_t, time0: c.time_t) callconv(.c) f64 {
    return @as(f64, @floatFromInt(time1)) - @as(f64, @floatFromInt(time0));
}

export fn mktime(timeptr: *c.tm) callconv(.c) c.time_t {
    const input_year = @as(i64, @intCast(timeptr.tm_year)) + 1900;
    const input_month = @as(i64, @intCast(timeptr.tm_mon));
    const year_adjust = @divFloor(input_month, 12);
    const month_zero = @mod(input_month, 12);
    const normalized_year = input_year + year_adjust;
    const normalized_month: usize = @intCast(month_zero + 1);

    const days = daysFromCivil(normalized_year, normalized_month, 1) + (@as(i128, @intCast(timeptr.tm_mday)) - 1);
    const sod = @as(i128, @intCast(timeptr.tm_hour)) * 3600 +
        @as(i128, @intCast(timeptr.tm_min)) * 60 +
        @as(i128, @intCast(timeptr.tm_sec));
    const total = days * 86400 + sod;

    const result = std.math.cast(c.time_t, total) orelse {
        errno = c.ERANGE;
        return -1;
    };
    fillTmFromUnixSeconds(timeptr, total);
    return result;
}

export fn time(timer: ?*c.time_t) callconv(.c) c.time_t {
    trace.log("time {*}", .{timer});
    const now_zig = std.time.timestamp();
    const now = @as(c.time_t, @intCast(std.math.boolMask(c.time_t, true) & now_zig));
    if (timer) |_| {
        timer.?.* = now;
    }
    trace.log("time return {}", .{now});
    return now;
}

export fn asctime(timeptr: *const c.tm) callconv(.c) ?[*:0]u8 {
    if (timeptr.tm_wday < 0 or timeptr.tm_wday >= weekday_abbrev.len) return null;
    if (timeptr.tm_mon < 0 or timeptr.tm_mon >= month_abbrev.len) return null;
    // Keep this manual and unsigned. Zig's signed integer formatting with width
    // can emit leading '+' characters for positive values, which breaks libc's
    // fixed asctime layout.
    const rendered = std.fmt.bufPrint(
        global.asctime_buf[0 .. global.asctime_buf.len - 1],
        "{s} {s} {d: >2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n",
        .{
            weekday_abbrev[@intCast(timeptr.tm_wday)],
            month_abbrev[@intCast(timeptr.tm_mon)],
            @as(u32, @intCast(timeptr.tm_mday)),
            @as(u32, @intCast(timeptr.tm_hour)),
            @as(u32, @intCast(timeptr.tm_min)),
            @as(u32, @intCast(timeptr.tm_sec)),
            @as(u32, @intCast(@as(i64, @intCast(timeptr.tm_year)) + 1900)),
        },
    ) catch return null;
    global.asctime_buf[rendered.len] = 0;
    return &global.asctime_buf;
}

export fn ctime(timer: *const c.time_t) callconv(.c) ?[*:0]u8 {
    const tm = localtime(timer) orelse return null;
    return asctime(tm);
}

export fn gmtime(timer: *const c.time_t) callconv(.c) ?*c.tm {
    fillTmFromUnixSeconds(&global.gmtime_tm, timer.*);
    return &global.gmtime_tm;
}

export fn localtime(timer: *const c.time_t) callconv(.c) ?*c.tm {
    fillTmFromUnixSeconds(&global.localtime_tm, timer.*);
    return &global.localtime_tm;
}

const weekday_abbrev = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_abbrev = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const StrftimeWriter = struct {
    dest: [*]u8,
    maxsize: usize,
    len: usize = 0,

    fn appendByte(self: *StrftimeWriter, value: u8) bool {
        if (self.len + 1 >= self.maxsize) return false;
        self.dest[self.len] = value;
        self.len += 1;
        return true;
    }

    fn appendSlice(self: *StrftimeWriter, value: []const u8) bool {
        if (self.len + value.len >= self.maxsize) return false;
        @memcpy(self.dest[self.len..][0..value.len], value);
        self.len += value.len;
        return true;
    }

    fn appendRepeated(self: *StrftimeWriter, value: u8, count: usize) bool {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (!self.appendByte(value)) return false;
        }
        return true;
    }
};

const YearFormatOptions = struct {
    width: ?usize = null,
    plus_flag: bool = false,
    default_width: usize = 4,
    sign_for_large_without_width: bool = true,
};

fn tmYear(tm: *const c.tm) i64 {
    return @as(i64, @intCast(tm.tm_year)) + 1900;
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn civilFromDays(days: i128) struct { year: i64, month: usize, day: usize } {
    const z = days + 719468;
    const era = if (z >= 0)
        @divFloor(z, 146097)
    else
        @divFloor(z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month_adjust: i128 = if (mp < 10) 3 else -9;
    const month = mp + month_adjust;
    if (month <= 2) year += 1;
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

fn fillTmFromUnixSeconds(out: *c.tm, unix_seconds: anytype) void {
    const total: i128 = @intCast(unix_seconds);
    const days = @divFloor(total, 86400);
    const rem = @mod(total, 86400);
    const civil = civilFromDays(days);
    const yday = days - daysFromCivil(civil.year, 1, 1);
    const wday = @mod(days + 4, 7);

    out.tm_sec = @as(c_int, @intCast(@mod(rem, 60)));
    out.tm_min = @as(c_int, @intCast(@divFloor(@mod(rem, 3600), 60)));
    out.tm_hour = @as(c_int, @intCast(@divFloor(rem, 3600)));
    out.tm_mday = @as(c_int, @intCast(civil.day));
    out.tm_mon = @as(c_int, @intCast(civil.month - 1));
    out.tm_year = @as(c_int, @intCast(civil.year - 1900));
    out.tm_wday = @as(c_int, @intCast(wday));
    out.tm_yday = @as(c_int, @intCast(yday));
    out.tm_isdst = 0;
}

fn daysFromCivil(year: i64, month: usize, day: usize) i128 {
    var y: i128 = year;
    const m: i128 = @intCast(month);
    const d: i128 = @intCast(day);
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const month_offset: i128 = if (m > 2) -3 else 9;
    const mp = m + month_offset;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn weekdayFromCivil(year: i64, month: usize, day: usize) u8 {
    const weekday = @mod(daysFromCivil(year, month, day) + 4, 7);
    return @intCast(weekday);
}

fn isoWeeksInYear(year: i64) u8 {
    const jan1_wday = weekdayFromCivil(year, 1, 1);
    const jan1_iso = if (jan1_wday == 0) @as(u8, 7) else jan1_wday;
    return if (jan1_iso == 4 or (jan1_iso == 3 and isLeapYear(year))) 53 else 52;
}

fn isoWeekYear(tm: *const c.tm) struct { week: u8, year: i64 } {
    const year = tmYear(tm);
    const yday: i64 = @intCast(tm.tm_yday);
    const wday: i64 = @intCast(tm.tm_wday);
    const iso_wday = if (wday == 0) @as(i64, 7) else wday;

    var week = @divFloor(yday + 11 - iso_wday, 7);
    var iso_year = year;
    if (week < 1) {
        iso_year -= 1;
        week = isoWeeksInYear(iso_year);
    } else {
        const weeks = isoWeeksInYear(year);
        if (week > weeks) {
            iso_year += 1;
            week = 1;
        }
    }

    return .{ .week = @intCast(week), .year = iso_year };
}

fn appendUnsignedPadded(writer: *StrftimeWriter, value: u64, min_width: usize, pad: u8) bool {
    var num_buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&num_buf, "{}", .{value}) catch return false;
    if (digits.len < min_width and !writer.appendRepeated(pad, min_width - digits.len)) return false;
    return writer.appendSlice(digits);
}

fn appendSignedPadded(writer: *StrftimeWriter, value: i64, min_width: usize, pad: u8) bool {
    var sign: ?u8 = null;
    var abs_value: u64 = undefined;
    if (value < 0) {
        sign = '-';
        abs_value = @intCast(-@as(i128, value));
    } else {
        abs_value = @intCast(value);
    }

    var num_buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&num_buf, "{}", .{abs_value}) catch return false;
    const sign_len: usize = if (sign != null) 1 else 0;
    const digit_width = if (min_width > sign_len) min_width - sign_len else digits.len;

    if (sign) |ch| {
        if (!writer.appendByte(ch)) return false;
    }
    if (digits.len < digit_width and !writer.appendRepeated(pad, digit_width - digits.len)) return false;
    return writer.appendSlice(digits);
}

fn appendYearFormatted(writer: *StrftimeWriter, year: i64, options: YearFormatOptions) bool {
    const abs_year: u128 = if (year < 0) @intCast(-@as(i128, year)) else @intCast(year);
    var digits_buf: [64]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{}", .{abs_year}) catch return false;

    var sign: ?u8 = null;
    if (year < 0) {
        sign = '-';
    } else if (options.plus_flag) {
        if (options.width) |width| {
            if (digits.len < width) sign = '+';
        } else if (digits.len > options.default_width) {
            sign = '+';
        }
    } else if (options.width == null and options.sign_for_large_without_width and digits.len > options.default_width) {
        sign = '+';
    }

    const sign_len: usize = if (sign != null) 1 else 0;
    const min_digits: usize = if (options.width) |width|
        if (width > sign_len) width - sign_len else digits.len
    else if (year >= 0 and digits.len < options.default_width)
        options.default_width
    else
        digits.len;

    if (sign) |ch| {
        if (!writer.appendByte(ch)) return false;
    }
    if (digits.len < min_digits and !writer.appendRepeated('0', min_digits - digits.len)) return false;
    return writer.appendSlice(digits);
}

fn appendTimeSecondsSinceEpoch(writer: *StrftimeWriter, tm: *const c.tm) bool {
    const year = tmYear(tm);
    const month: usize = @intCast(@as(i64, @intCast(tm.tm_mon)) + 1);
    const day: usize = @intCast(tm.tm_mday);
    const days = daysFromCivil(year, month, day);
    const sod = @as(i128, @intCast(tm.tm_hour)) * 3600 + @as(i128, @intCast(tm.tm_min)) * 60 + @as(i128, @intCast(tm.tm_sec));
    const total = days * 86400 + sod;
    const ts = std.math.cast(c.time_t, total) orelse return false;

    var num_buf: [64]u8 = undefined;
    const digits = std.fmt.bufPrint(&num_buf, "{}", .{ts}) catch return false;
    return writer.appendSlice(digits);
}

fn appendStrftimeDirective(
    writer: *StrftimeWriter,
    spec: u8,
    width: ?usize,
    plus_flag: bool,
    tm: *const c.tm,
) bool {
    const year = tmYear(tm);
    switch (spec) {
        '%' => return writer.appendByte('%'),
        'a' => {
            if (tm.tm_wday < 0 or tm.tm_wday >= weekday_abbrev.len) return false;
            return writer.appendSlice(weekday_abbrev[@intCast(tm.tm_wday)]);
        },
        'b' => {
            if (tm.tm_mon < 0 or tm.tm_mon >= month_abbrev.len) return false;
            return writer.appendSlice(month_abbrev[@intCast(tm.tm_mon)]);
        },
        'c' => {
            if (!appendStrftimeDirective(writer, 'a', null, false, tm)) return false;
            if (!writer.appendByte(' ')) return false;
            if (!appendStrftimeDirective(writer, 'b', null, false, tm)) return false;
            if (!writer.appendByte(' ')) return false;
            if (!appendUnsignedPadded(writer, @intCast(tm.tm_mday), 2, ' ')) return false;
            if (!writer.appendByte(' ')) return false;
            if (!appendStrftimeDirective(writer, 'T', null, false, tm)) return false;
            if (!writer.appendByte(' ')) return false;
            return appendYearFormatted(writer, year, .{});
        },
        'C' => return appendYearFormatted(writer, @divFloor(year, 100), .{
            .width = width,
            .plus_flag = plus_flag,
            .default_width = 2,
            .sign_for_large_without_width = false,
        }),
        'd' => return appendUnsignedPadded(writer, @intCast(tm.tm_mday), 2, '0'),
        'e' => return appendUnsignedPadded(writer, @intCast(tm.tm_mday), 2, ' '),
        'F' => {
            const year_width: ?usize = if (width) |w| if (w > 6) w - 6 else 1 else null;
            if (!appendYearFormatted(writer, year, .{ .width = year_width, .plus_flag = plus_flag })) return false;
            if (!writer.appendByte('-')) return false;
            if (!appendUnsignedPadded(writer, @intCast(@as(i64, @intCast(tm.tm_mon)) + 1), 2, '0')) return false;
            if (!writer.appendByte('-')) return false;
            return appendUnsignedPadded(writer, @intCast(tm.tm_mday), 2, '0');
        },
        'g', 'G', 'V' => {
            const iso = isoWeekYear(tm);
            if (spec == 'V') return appendUnsignedPadded(writer, iso.week, 2, '0');
            if (spec == 'g') {
                const low = @mod(iso.year, 100);
                return appendUnsignedPadded(writer, @intCast(low), 2, '0');
            }
            return appendYearFormatted(writer, iso.year, .{ .width = width, .plus_flag = plus_flag });
        },
        'H' => return appendUnsignedPadded(writer, @intCast(tm.tm_hour), 2, '0'),
        'I' => {
            const hour: u8 = @intCast(tm.tm_hour);
            const hour12: u8 = if (hour % 12 == 0) 12 else hour % 12;
            return appendUnsignedPadded(writer, hour12, 2, '0');
        },
        'm' => return appendUnsignedPadded(writer, @intCast(@as(i64, @intCast(tm.tm_mon)) + 1), 2, '0'),
        'M' => return appendUnsignedPadded(writer, @intCast(tm.tm_min), 2, '0'),
        'p' => return writer.appendSlice(if (tm.tm_hour >= 12) "PM" else "AM"),
        'r' => {
            if (!appendStrftimeDirective(writer, 'I', null, false, tm)) return false;
            if (!writer.appendByte(':')) return false;
            if (!appendStrftimeDirective(writer, 'M', null, false, tm)) return false;
            if (!writer.appendByte(':')) return false;
            if (!appendStrftimeDirective(writer, 'S', null, false, tm)) return false;
            if (!writer.appendByte(' ')) return false;
            return appendStrftimeDirective(writer, 'p', null, false, tm);
        },
        's' => return appendTimeSecondsSinceEpoch(writer, tm),
        'S' => return appendUnsignedPadded(writer, @intCast(tm.tm_sec), 2, '0'),
        'T', 'X' => {
            if (!appendStrftimeDirective(writer, 'H', null, false, tm)) return false;
            if (!writer.appendByte(':')) return false;
            if (!appendStrftimeDirective(writer, 'M', null, false, tm)) return false;
            if (!writer.appendByte(':')) return false;
            return appendStrftimeDirective(writer, 'S', null, false, tm);
        },
        'U' => {
            const wday: i64 = @intCast(tm.tm_wday);
            const yday: i64 = @intCast(tm.tm_yday);
            const week = @divFloor(yday + 7 - wday, 7);
            return appendUnsignedPadded(writer, @intCast(week), 2, '0');
        },
        'W' => {
            const wday: i64 = @intCast(tm.tm_wday);
            const yday: i64 = @intCast(tm.tm_yday);
            const monday_first_wday = @mod(wday + 6, 7);
            const week = @divFloor(yday + 7 - monday_first_wday, 7);
            return appendUnsignedPadded(writer, @intCast(week), 2, '0');
        },
        'x' => {
            if (!appendStrftimeDirective(writer, 'm', null, false, tm)) return false;
            if (!writer.appendByte('/')) return false;
            if (!appendStrftimeDirective(writer, 'd', null, false, tm)) return false;
            if (!writer.appendByte('/')) return false;
            return appendStrftimeDirective(writer, 'y', null, false, tm);
        },
        'y' => {
            const low = @mod(year, 100);
            return appendUnsignedPadded(writer, @intCast(low), 2, '0');
        },
        'Y' => return appendYearFormatted(writer, year, .{ .width = width, .plus_flag = plus_flag }),
        else => return false,
    }
}

export fn strftime(s: [*]u8, maxsize: usize, format: [*:0]const u8, timeptr: *const c.tm) callconv(.c) usize {
    if (maxsize == 0) return 0;

    var writer = StrftimeWriter{
        .dest = s,
        .maxsize = maxsize,
    };

    var i: usize = 0;
    while (true) : (i += 1) {
        const ch = format[i];
        if (ch == 0) break;
        if (ch != '%') {
            if (!writer.appendByte(ch)) return 0;
            continue;
        }

        i += 1;
        var spec = format[i];
        if (spec == 0) return 0;

        var plus_flag = false;
        if (spec == '+') {
            plus_flag = true;
            i += 1;
            spec = format[i];
        }

        var width: ?usize = null;
        if (std.ascii.isDigit(spec)) {
            var parsed: usize = 0;
            while (std.ascii.isDigit(spec)) : ({
                i += 1;
                spec = format[i];
            }) {
                parsed = parsed * 10 + (spec - '0');
            }
            width = parsed;
        }

        if (!appendStrftimeDirective(&writer, spec, width, plus_flag, timeptr)) return 0;
    }

    writer.dest[writer.len] = 0;
    return writer.len;
}

// --------------------------------------------------------------------------------
// ctype
// --------------------------------------------------------------------------------
export fn isalnum(char: c_int) callconv(.c) c_int {
    trace.log("isalnum {}", .{char});
    return @intFromBool(std.ascii.isAlphanumeric(std.math.cast(u8, char) orelse return 0));
}

export fn toupper(char: c_int) callconv(.c) c_int {
    trace.log("toupper {}", .{char});
    return std.ascii.toUpper(std.math.cast(u8, char) orelse return char);
}

export fn tolower(char: c_int) callconv(.c) c_int {
    trace.log("tolower {}", .{char});
    return std.ascii.toLower(std.math.cast(u8, char) orelse return char);
}

export fn isascii(char: c_int) callconv(.c) c_int {
    return @intFromBool(char >= 0 and char <= 0x7f);
}

export fn toascii(char: c_int) callconv(.c) c_int {
    return char & 0x7f;
}

export fn isspace(char: c_int) callconv(.c) c_int {
    trace.log("isspace {}", .{char});
    return @intFromBool(std.ascii.isWhitespace(std.math.cast(u8, char) orelse return 0));
}

export fn isblank(char: c_int) callconv(.c) c_int {
    const c_u8 = std.math.cast(u8, char) orelse return 0;
    return @intFromBool(c_u8 == ' ' or c_u8 == '\t');
}

export fn isxdigit(char: c_int) callconv(.c) c_int {
    trace.log("isxdigit {}", .{char});
    return @intFromBool(std.ascii.isHex(std.math.cast(u8, char) orelse return 0));
}

export fn iscntrl(char: c_int) callconv(.c) c_int {
    trace.log("iscntrl {}", .{char});
    return @intFromBool(std.ascii.isControl(std.math.cast(u8, char) orelse return 0));
}

export fn isdigit(char: c_int) callconv(.c) c_int {
    trace.log("isdigit {}", .{char});
    return @intFromBool(std.ascii.isDigit(std.math.cast(u8, char) orelse return 0));
}

export fn isalpha(char: c_int) callconv(.c) c_int {
    trace.log("isalhpa {}", .{char});
    return @intFromBool(std.ascii.isAlphabetic(std.math.cast(u8, char) orelse return 0));
}

export fn isgraph(char: c_int) callconv(.c) c_int {
    trace.log("isgraph {}", .{char});
    return @intFromBool(std.ascii.isPrint(std.math.cast(u8, char) orelse return 0));
}

export fn islower(char: c_int) callconv(.c) c_int {
    trace.log("islower {}", .{char});
    return @intFromBool(std.ascii.isLower(std.math.cast(u8, char) orelse return 0));
}

export fn isupper(char: c_int) callconv(.c) c_int {
    trace.log("isupper {}", .{char});
    return @intFromBool(std.ascii.isUpper(std.math.cast(u8, char) orelse return 0));
}

export fn ispunct(char: c_int) callconv(.c) c_int {
    trace.log("ispunct {}", .{char});
    const c_u8 = std.math.cast(u8, char) orelse return 0;
    return @intFromBool(std.ascii.isPrint(c_u8) and !std.ascii.isAlphanumeric(c_u8));
}

export fn isprint(char: c_int) callconv(.c) c_int {
    trace.log("isprint {}", .{char});
    return @intFromBool(std.ascii.isPrint(std.math.cast(u8, char) orelse return 0));
}

// --------------------------------------------------------------------------------
// assert
// --------------------------------------------------------------------------------
export fn __zassert_fail(
    expression: [*:0]const u8,
    file: [*:0]const u8,
    line: c_int,
    func: [*:0]const u8,
) callconv(.c) void {
    trace.log("assert failed '{s}' ('{s}' line {d} function '{s}')", .{ expression, file, line, func });
    abort();
}

// --------------------------------------------------------------------------------
// setjmp
// --------------------------------------------------------------------------------
const has_x86_64_setjmp_asm = builtin.cpu.arch == .x86_64;
const has_aarch64_setjmp_asm = builtin.cpu.arch == .aarch64;

fn setjmp_x86_64() callconv(.naked) c_int {
    if (builtin.os.tag == .windows) {
        asm volatile (
        // Win64: env in rcx
            \\movq %%rbx,(%%rcx)
            \\movq %%rbp,8(%%rcx)
            \\movq %%r12,16(%%rcx)
            \\movq %%r13,24(%%rcx)
            \\movq %%r14,32(%%rcx)
            \\movq %%r15,40(%%rcx)
            \\movq %%rdi,48(%%rcx)
            \\movq %%rsi,56(%%rcx)
            \\leaq 8(%%rsp),%%rdx
            \\movq %%rdx,64(%%rcx)
            \\movq (%%rsp),%%rdx
            \\movq %%rdx,72(%%rcx)
            \\xorl %%eax,%%eax
            \\ret
        );
    } else {
        asm volatile (
        // SysV: env in rdi
            \\movq %%rbx,(%%rdi)
            \\movq %%rbp,8(%%rdi)
            \\movq %%r12,16(%%rdi)
            \\movq %%r13,24(%%rdi)
            \\movq %%r14,32(%%rdi)
            \\movq %%r15,40(%%rdi)
            \\leaq 8(%%rsp),%%rdx
            \\movq %%rdx,48(%%rdi)
            \\movq (%%rsp),%%rdx
            \\movq %%rdx,56(%%rdi)
            \\xorl %%eax,%%eax
            \\ret
        );
    }
}

fn longjmp_x86_64() callconv(.naked) noreturn {
    if (builtin.os.tag == .windows) {
        asm volatile (
        // Win64: env in rcx, val in edx
            \\xorl %%eax,%%eax
            \\cmpl $1,%%edx
            \\adcl %%edx,%%eax
            \\movq (%%rcx),%%rbx
            \\movq 8(%%rcx),%%rbp
            \\movq 16(%%rcx),%%r12
            \\movq 24(%%rcx),%%r13
            \\movq 32(%%rcx),%%r14
            \\movq 40(%%rcx),%%r15
            \\movq 48(%%rcx),%%rdi
            \\movq 56(%%rcx),%%rsi
            \\movq 64(%%rcx),%%rsp
            \\jmpq *72(%%rcx)
        );
    } else {
        asm volatile (
        // SysV: env in rdi, val in esi
            \\xorl %%eax,%%eax
            \\cmpl $1,%%esi
            \\adcl %%esi,%%eax
            \\movq (%%rdi),%%rbx
            \\movq 8(%%rdi),%%rbp
            \\movq 16(%%rdi),%%r12
            \\movq 24(%%rdi),%%r13
            \\movq 32(%%rdi),%%r14
            \\movq 40(%%rdi),%%r15
            \\movq 48(%%rdi),%%rsp
            \\jmpq *56(%%rdi)
        );
    }
}

fn setjmp_aarch64() callconv(.naked) c_int {
    asm volatile (
        \\stp x19, x20, [x0, #0]
        \\stp x21, x22, [x0, #16]
        \\stp x23, x24, [x0, #32]
        \\stp x25, x26, [x0, #48]
        \\stp x27, x28, [x0, #64]
        \\stp x29, x30, [x0, #80]
        \\mov x2, sp
        \\str x2, [x0, #96]
        \\stp d8, d9, [x0, #104]
        \\stp d10, d11, [x0, #120]
        \\stp d12, d13, [x0, #136]
        \\stp d14, d15, [x0, #152]
        \\mov w0, wzr
        \\ret
    );
}

fn longjmp_aarch64() callconv(.naked) noreturn {
    asm volatile (
        \\ldp x19, x20, [x0, #0]
        \\ldp x21, x22, [x0, #16]
        \\ldp x23, x24, [x0, #32]
        \\ldp x25, x26, [x0, #48]
        \\ldp x27, x28, [x0, #64]
        \\ldp x29, x30, [x0, #80]
        \\ldr x2, [x0, #96]
        \\ldp d8, d9, [x0, #104]
        \\ldp d10, d11, [x0, #120]
        \\ldp d12, d13, [x0, #136]
        \\ldp d14, d15, [x0, #152]
        \\mov sp, x2
        \\mov w0, w1
        \\cmp w0, #0
        \\cinc w0, w0, eq
        \\ret
    );
}

fn setjmp_fallback(env: c.jmp_buf) callconv(.c) c_int {
    _ = env;
    errno = errnoConst("ENOSYS", c.EINVAL);
    return 0;
}
fn longjmp_fallback(env: c.jmp_buf, val: c_int) callconv(.c) noreturn {
    _ = env;
    _ = val;
    std.posix.abort();
}
comptime {
    if (has_x86_64_setjmp_asm) {
        @export(&setjmp_x86_64, .{ .name = "setjmp" });
        @export(&setjmp_x86_64, .{ .name = "_setjmp" });
        @export(&setjmp_x86_64, .{ .name = "__setjmp" });

        @export(&longjmp_x86_64, .{ .name = "longjmp" });
        @export(&longjmp_x86_64, .{ .name = "_longjmp" });
        @export(&longjmp_x86_64, .{ .name = "__longjmp" });
    } else if (has_aarch64_setjmp_asm) {
        @export(&setjmp_aarch64, .{ .name = "setjmp" });
        @export(&setjmp_aarch64, .{ .name = "_setjmp" });
        @export(&setjmp_aarch64, .{ .name = "__setjmp" });

        @export(&longjmp_aarch64, .{ .name = "longjmp" });
        @export(&longjmp_aarch64, .{ .name = "_longjmp" });
        @export(&longjmp_aarch64, .{ .name = "__longjmp" });
    } else {
        @export(&setjmp_fallback, .{ .name = "setjmp" });
        @export(&setjmp_fallback, .{ .name = "_setjmp" });
        @export(&setjmp_fallback, .{ .name = "__setjmp" });

        @export(&longjmp_fallback, .{ .name = "longjmp" });
        @export(&longjmp_fallback, .{ .name = "_longjmp" });
        @export(&longjmp_fallback, .{ .name = "__longjmp" });
    }
}
