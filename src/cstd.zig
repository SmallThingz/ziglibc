const builtin = @import("builtin");
const std = @import("std");

const c = @cImport({
    // problem with LONG_MIN/LONG_MAX, they are currently assuming 64 bit
    //@cInclude("limits.h");
    @cInclude("errno.h");
    @cInclude("stdarg.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("setjmp.h");
    @cInclude("locale.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("limits.h");
});

const trace = @import("trace.zig");

// __main appears to be a design inherited by LLVM from gcc.
// it's typically provided by libgcc and is used to call constructors
fn __main() callconv(.c) void {
    stdin.fd = std.os.windows.peb().ProcessParameters.hStdInput;
    stdout.fd = std.os.windows.peb().ProcessParameters.hStdOutput;
    stderr.fd = std.os.windows.peb().ProcessParameters.hStdError;

    // TODO: call constructors
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
};

// --------------------------------------------------------------------------------
// errno
// --------------------------------------------------------------------------------
export var errno: c_int = 0;

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
    @panic("abort");
}

// TODO: can name be null?
// TODO: should we detect and do something different if there is a '=' in name?
export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    trace.log("getenv {f}", .{trace.fmtStr(name)});
    return null; // not implemented
    //const name_len = std.mem.len(name);
    //var e: ?[*:0]u8 = environ;
}

export fn system(string: ?[*:0]const u8) callconv(.c) c_int {
    trace.log("system {f}", .{trace.fmtStr(string)});
    trace.log("system returning -1 to indicate it is not supported yet", .{});
    errno = c.ENOSYS;
    return -1; // system not implemented yet
}

/// alloc_align is the maximum alignment needed for all types
/// since malloc is not type aware, it just aligns every allocation
/// to accomodate the maximum possible alignment that could be needed.
///
/// TODO: this should probably be in the zig std library somewhere.
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
    return @as(c_int, @bitCast(@as(c_uint, @intCast(global.rand.random().int(std.math.IntFittingRange(0, c.RAND_MAX))))));
}

export fn abs(j: c_int) callconv(.c) c_int {
    return if (j >= 0) j else -j;
}

export fn atoi(nptr: [*:0]const u8) callconv(.c) c_int {
    // TODO: atoi hase some behavior difference on error, get a test for
    //       these differences
    return strto(c_int, nptr, null, 10);
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
// TODO: strnlen exists in some libc implementations, it might be defined by posix so
//       I should probably move it to the posix lib
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
    _ = s1;
    _ = s2;
    @panic("strcoll not implemented");
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

// TODO: find out which standard this function comes from
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
export fn strlcpy(dst: [*]u8, src: [*:0]const u8, size: usize) callconv(.c) usize {
    trace.log("strncpy {*} {*} n={}", .{ dst, src, size });
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == size) {
            if (size > 0)
                dst[size - 1] = 0;
            return i + strlen(src + i);
        }
        dst[i] = src[i];
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

    if (optional_endptr) |endptr| endptr.* = next;
    if (next == digit_start) {
        errno = c.EINVAL; // TODO: is this right?
    } else {
        trace.log("strto str='{s}' result={}", .{ start[0 .. @intFromPtr(next) - @intFromPtr(start)], x });
    }
    return x;
}

export fn strtod(nptr: [*:0]const u8, endptr: ?*[*:0]const u8) callconv(.c) f64 {
    trace.log("strtod {f}", .{trace.fmtStr(nptr)});
    const str_len: usize = if (endptr) |e| @intFromPtr(e.*) - @intFromPtr(nptr) else std.mem.len(nptr);
    if (str_len == 0) {
        return 0;
    }
    const result = std.fmt.parseFloat(f64, nptr[0..str_len]) catch |err| switch (err) {
        error.InvalidCharacter => {
            std.debug.panic("todo: strtod handle InvalidCharacter for '{s}'", .{nptr[0..str_len]});
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

export fn strerror(errnum: c_int) callconv(.c) [*:0]const u8 {
    std.log.warn("sterror (num={}) not implemented", .{errnum});
    _ = std.fmt.bufPrint(&global.tmp_strerror_buffer, "{}", .{errnum}) catch @panic("BUG");
    return @as([*:0]const u8, @ptrCast(&global.tmp_strerror_buffer));
}

// --------------------------------------------------------------------------------
// signal
// --------------------------------------------------------------------------------
const SignalFn = switch (builtin.zig_backend) {
    .stage1 => fn (c_int) callconv(.c) void,
    else => *const fn (c_int) callconv(.c) void,
};
export fn signal(sig: c_int, func: SignalFn) callconv(.c) ?SignalFn {
    if (builtin.os.tag == .windows) {
        // TODO: maybe we can emulate/handle some signals?
        trace.log("ignoring the 'signal' function (sig={}) on windows", .{sig});
        return null;
    }
    if (builtin.os.tag == .linux) {
        var action = std.posix.Sigaction{
            .handler = .{ .handler = func },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = std.posix.SA.RESTART,
        };
        var old_action: std.posix.Sigaction = undefined;
        switch (std.posix.errno(std.posix.system.sigaction(
            @as(u6, @intCast(sig)),
            &action,
            &old_action,
        ))) {
            .SUCCESS => return old_action.handler.handler,
            else => |e| {
                errno = @intFromEnum(e);
                // translate-c having a hard time with this one
                //return c.SIG_ERR;
                return @as(?SignalFn, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
            },
        }
    }
    @panic("signal not implemented");
}

// --------------------------------------------------------------------------------
// stdio
// --------------------------------------------------------------------------------
const global = struct {
    var rand: std.Random.DefaultPrng = undefined;

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .MutexType = std.Thread.Mutex,
    }){};

    var strtok_ptr: ?[*:0]u8 = undefined;

    // TODO: remove this global limit on file handles
    //       probably do an array of pages holding the file objects.
    //       the address to any file can be done in O(1) by decoding
    //       the page index and file offset
    const max_file_count = 100;
    var files_reserved: [max_file_count]bool = [_]bool{ true, true, true } ++ ([_]bool{false} ** (max_file_count - 3));
    var files: [max_file_count]c.FILE = [_]c.FILE{
        .{ .fd = if (builtin.os.tag == .windows) undefined else std.posix.STDIN_FILENO, .eof = 0, .errno = 0 },
        .{ .fd = if (builtin.os.tag == .windows) undefined else std.posix.STDOUT_FILENO, .eof = 0, .errno = 0 },
        .{ .fd = if (builtin.os.tag == .windows) undefined else std.posix.STDERR_FILENO, .eof = 0, .errno = 0 },
    } ++ ([_]c.FILE{.{ .fd = if (builtin.os.tag == .windows) undefined else -1, .eof = 0, .errno = 0 }} ** (max_file_count - 3));

    fn reserveFile() *c.FILE {
        var i: usize = 0;
        while (i < files_reserved.len) : (i += 1) {
            if (!@atomicRmw(bool, &files_reserved[i], .Xchg, true, .seq_cst)) {
                files[i].eof = 0;
                files[i].errno = 0;
                return &files[i];
            }
        }
        @panic("out of file handles");
    }
    fn releaseFile(file: *c.FILE) void {
        const i = (@intFromPtr(file) - @intFromPtr(&files[0])) / @sizeOf(c.FILE);
        if (!@atomicRmw(bool, &files_reserved[i], .Xchg, false, .seq_cst)) {
            std.debug.panic("released FILE (i={} ptr={*}) that was not reserved", .{ i, file });
        }
    }

    // TODO: remove this.  Just using it to return error numbers as strings for now
    var tmp_strerror_buffer: [30]u8 = undefined;

    var atexit_mutex = std.Thread.Mutex{};
    var atexit_started = false;
    // TODO: these don't need to be contiguous, use a chain of fixed size chunks
    //       that don't need to move/be resized ChunkedArrayList or something
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

export const stdin: *c.FILE = &global.files[0];
export const stdout: *c.FILE = &global.files[1];
export const stderr: *c.FILE = &global.files[2];

// used by posix.zig
export fn __zreserveFile() callconv(.c) ?*c.FILE {
    return global.reserveFile();
}

export fn remove(filename: [*:0]const u8) callconv(.c) c_int {
    trace.log("remove {f}", .{trace.fmtStr(filename)});
    @panic("remove not implemented");
}

export fn rename(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    trace.log("rename {f} {f}", .{ trace.fmtStr(old), trace.fmtStr(new) });
    @panic("rename not implemented");
}

export fn getchar() callconv(.c) c_int {
    return getc(stdin);
}

export fn getc(stream: *c.FILE) callconv(.c) c_int {
    if (stream.eof != 0) @panic("getc, eof not 0 not implemented");
    trace.log("getc {*}", .{stream});

    if (builtin.os.tag == .windows) {
        var buf: [1]u8 = undefined;
        const len = _fread_buf(&buf, 1, stream);
        if (len == 0) return c.EOF;
        std.debug.assert(len == 1);
        return buf[0];
    }

    var buf: [1]u8 = undefined;
    const rc = std.posix.system.read(stream.fd, &buf, 1);
    if (rc == 1) {
        trace.log("getc return {}", .{buf[0]});
        return buf[0];
    }
    stream.errno = if (rc == 0) 0 else @intFromEnum(std.posix.errno(rc));
    trace.log("getc return EOF, errno={}", .{stream.errno});
    return c.EOF;
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
    if (stream.eof != 0) @panic("ungetc, eof not 0 not implemented");
    _ = char;
    @panic("ungetc not implemented");
}

export fn _fread_buf(ptr: [*]u8, size: usize, stream: *c.FILE) callconv(.c) usize {
    // TODO: should I check stream.eof here?

    if (builtin.os.tag == .windows) {
        const actual_read_len = @as(u32, @intCast(@min(@as(u32, std.math.maxInt(u32)), size)));
        while (true) {
            var amt_read: u32 = undefined;
            // TODO: is stream.fd.? right?
            if (std.os.windows.kernel32.ReadFile(stream.fd.?, ptr, actual_read_len, &amt_read, null) == 0) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    .OPERATION_ABORTED => continue,
                    .BROKEN_PIPE => return 0,
                    .HANDLE_EOF => return 0,
                    else => |err| std.debug.panic("ReadFile unexpected error {}", .{err}),
                }
            }
            return @as(usize, @intCast(amt_read));
        }
    }

    // Prevents EINVAL.
    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    const adjusted_len = @min(max_count, size);

    const rc = std.posix.system.read(stream.fd, ptr, adjusted_len);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            if (rc == 0) stream.eof = 1;
            return @as(usize, @intCast(rc));
        },
        else => |e| {
            errno = @intFromEnum(e);
            return 0;
        },
    }
}

export fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *c.FILE) callconv(.c) usize {
    if (stream.eof != 0) @panic("fread, eof not 0 not implemented");
    const total = size * nmemb;
    const result = _fread_buf(ptr, total, stream);
    if (result == 0) return 0;
    if (result == total) return nmemb;
    // TODO: if length read is not aligned then we need to leave it
    //       in an internal read buffer inside FILE
    //       for now we'll crash if it's not aligned
    return @divExact(result, size);
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
    if (builtin.os.tag == .windows) {
        var create_disposition: u32 = std.os.windows.OPEN_EXISTING;
        var access: u32 = 0;
        for (std.mem.span(mode)) |mode_char| {
            if (mode_char == 'r') {
                access |= std.os.windows.GENERIC_READ;
            } else if (mode_char == 'w') {
                access |= std.os.windows.GENERIC_WRITE;
                create_disposition = std.os.windows.CREATE_ALWAYS;
            } else if (mode_char == 'b') {
                // not really sure what this is supposed to do yet, ignore it for now
            } else {
                std.debug.panic("unhandled open flag '{c}' (from {f})", .{ mode_char, trace.fmtStr(mode) });
            }
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
            // TODO: do I need to set errno?
            errno = @intFromEnum(std.os.windows.kernel32.GetLastError());
            return null;
        }
        const file = global.reserveFile();
        file.fd = fd;
        file.eof = 0;
        return file;
    }

    var flags = std.posix.O{};
    for (std.mem.span(mode)) |mode_char| {
        if (mode_char == 'r') {
            flags.ACCMODE = .RDONLY;
        } else if (mode_char == 'w') {
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.TRUNC = true;
        } else if (mode_char == 'b') {
            // not really sure what this is supposed to do yet, ignore it for now
        } else {
            std.debug.panic("unhandled open flag '{c}' (from {f})", .{ mode_char, trace.fmtStr(mode) });
        }
    }
    if (force_largefile and @hasField(@TypeOf(flags), "LARGEFILE")) {
        flags.LARGEFILE = true;
    }
    const fd = std.posix.system.open(filename, @bitCast(flags), @as(std.posix.mode_t, 0o666));
    switch (std.posix.errno(fd)) {
        .SUCCESS => {},
        else => |e| {
            errno = @intFromEnum(e);
            trace.log("{s} return null (errno={})", .{ func_name, errno });
            return null;
        },
    }
    const file = global.reserveFile();
    file.fd = @as(c_int, @intCast(fd));
    file.eof = 0;
    return file;
}

pub export fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    return fopenImpl(filename, mode, false, "fopen");
}

pub export fn fopen64(filename: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    return fopenImpl(filename, mode, true, "fopen64");
}

export fn freopen(filename: [*:0]const u8, mode: [*:0]const u8, stream: *c.FILE) callconv(.c) *c.FILE {
    _ = filename;
    _ = mode;
    _ = stream;
    @panic("freopen not implemented");
}

export fn fclose(stream: *c.FILE) callconv(.c) c_int {
    trace.log("fclose {*}", .{stream});
    if (builtin.os.tag == .windows) {
        if (windows.CloseHandle(stream.fd.?) == 0) {
            errno = @intFromEnum(std.os.windows.kernel32.GetLastError());
            return c.EOF;
        }
    } else {
        _ = std.posix.system.close(stream.fd);
    }
    global.releaseFile(stream);
    return 0;
}

export fn fseek(stream: *c.FILE, offset: c_long, whence: c_int) callconv(.c) c_int {
    trace.log("fseek {*} offset={} whence={}", .{ stream, offset, whence });

    if (builtin.os.tag == .windows) {
        @panic("fseek not implemented on Windows");
    }

    // woraround error in std/os/linux.zig: error: destination type 'usize' has size 4 but source type 'i64' has size 8
    // return syscall3(.lseek, @bitCast(usize, @as(isize, fd)), @bitCast(usize, offset), whence);
    //                                                                   ^
    if (@sizeOf(usize) == 4) @panic("not implemented");
    if (whence != c.SEEK_SET and whence != c.SEEK_CUR and whence != c.SEEK_END) {
        errno = c.EINVAL;
        stream.errno = errno;
        return -1;
    }
    const rc = if (builtin.os.tag == .linux)
        std.posix.system.lseek(stream.fd, @as(i64, @intCast(offset)), @as(usize, @intCast(whence)))
    else
        std.posix.system.lseek(stream.fd, @as(i64, @intCast(offset)), @as(c_int, @intCast(whence)));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {
            stream.eof = 0;
            stream.errno = 0;
            return 0;
        },
        else => |e| {
            errno = @intFromEnum(e);
            stream.errno = errno;
            return -1;
        },
    }
}

export fn ftell(stream: *c.FILE) callconv(.c) c_long {
    _ = stream;
    @panic("ftell not implemented");
}

export fn rewind(stream: *c.FILE) callconv(.c) void {
    trace.log("rewind {*}", .{stream});
    if (0 == fseek(stream, 0, c.SEEK_SET)) {
        stream.eof = 0;
        stream.errno = 0;
    }
}

// TODO: why is there a putc and an fputc function? They seem to be equivalent
//       so what's the history?
comptime {
    @export(&fputc, .{ .name = "putc" });
}

export fn fputc(character: c_int, stream: *c.FILE) callconv(.c) c_int {
    trace.log("fputc {} stream={*}", .{ character, stream });
    if (builtin.os.tag == .windows) {
        @panic("fputc not implemented");
    }
    const buf = [_]u8{@as(u8, @intCast(0xff & character))};
    const written = std.posix.system.write(stream.fd, &buf, 1);
    switch (std.posix.errno(written)) {
        .SUCCESS => {
            if (written == 1) return character;
            stream.errno = @intFromEnum(std.posix.E.IO);
            return c.EOF;
        },
        else => |e| {
            stream.errno = @intFromEnum(e);
            return c.EOF;
        },
    }
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
    long,
    long_long,
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

const VaListParam = if (builtin.os.tag == .windows)
    c.va_list
else if (@typeInfo(std.builtin.VaList) == .pointer)
    std.builtin.VaList
else
    *std.builtin.VaList;

const VaListCursor = if (builtin.os.tag == .windows)
    *c.va_list
else
    *std.builtin.VaList;

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

inline fn vaArgCompat(args: VaListCursor, comptime T: type) T {
    if (comptime builtin.os.tag == .windows) {
        return vaArgWindows(args, T);
    }
    return @cVaArg(args, T);
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
        if (fmt_slice[i] == 'l') {
            if (i + 1 < fmt_slice.len and fmt_slice[i + 1] == 'l') {
                spec_length = .long_long;
                i += 2;
            } else {
                spec_length = .long;
                i += 1;
            }
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
                    .long => formatIntCompat(&buf, vaArgCompat(args, c_long), 10),
                    .long_long => formatIntCompat(&buf, vaArgCompat(args, c_longlong), 10),
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
                    .long => formatIntCompat(&buf, vaArgCompat(args, c_ulong), base),
                    .long_long => formatIntCompat(&buf, vaArgCompat(args, c_ulonglong), base),
                };
                const written = writer.write(buf[0..len]);
                out_written.* += written;
                if (written != len) return false;
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

fn vfprintf(stream: *c.FILE, format: [*:0]const u8, arg: VaListParam) callconv(.c) c_int {
    var writer = FormatWriter{ .stream = stream };
    var written: usize = 0;
    const ok = if (comptime builtin.os.tag == .windows) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else if (comptime @typeInfo(std.builtin.VaList) == .pointer) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else vformat(&written, &writer, format, arg);
    if (ok) {
        return @intCast(written);
    } else {
        stream.errno = c.errno;
        return -1;
    }
}

fn vprintf(format: [*:0]const u8, arg: VaListParam) callconv(.c) c_int {
    return vfprintf(stdout, format, arg);
}

fn vsnprintf(s: [*]u8, n: usize, format: [*:0]const u8, arg: VaListParam) callconv(.c) c_int {
    var writer = FormatWriter{ .bounded = .{
        .buf = s,
        .len = n,
    } };
    var written: usize = 0;
    const ok = if (comptime builtin.os.tag == .windows) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else if (comptime @typeInfo(std.builtin.VaList) == .pointer) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else vformat(&written, &writer, format, arg);
    std.debug.assert(ok);
    if (written < n) s[written] = 0;
    return @intCast(written);
}

fn vsprintf(s: [*]u8, format: [*:0]const u8, arg: VaListParam) callconv(.c) c_int {
    var writer = FormatWriter{ .unbounded = .{
        .buf = s,
    } };
    var written: usize = 0;
    const ok = if (comptime builtin.os.tag == .windows) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else if (comptime @typeInfo(std.builtin.VaList) == .pointer) blk: {
        var va = arg;
        break :blk vformat(&written, &writer, format, &va);
    } else vformat(&written, &writer, format, arg);
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

fn vsscanf(s: [*:0]const u8, fmt: [*:0]const u8, arg: VaListParam) callconv(.c) c_int {
    var reader = FixedReader{ .buf = s };
    if (comptime builtin.os.tag == .windows) {
        var va = arg;
        return vscan(&reader, fmt, &va);
    } else if (comptime @typeInfo(std.builtin.VaList) == .pointer) {
        var va = arg;
        return vscan(&reader, fmt, &va);
    } else {
        return vscan(&reader, fmt, arg);
    }
}

comptime {
    @export(&vfprintf, .{ .name = "vfprintf" });
    @export(&vprintf, .{ .name = "vprintf" });
    @export(&vsnprintf, .{ .name = "vsnprintf" });
    @export(&vsprintf, .{ .name = "vsprintf" });
    @export(&vsscanf, .{ .name = "vsscanf" });
}

// TODO: can ptr be NULL?
// TODO: can stream be NULL (I don't think it can)
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

    // TODO: this implementation is very slow/inefficient
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

export fn tmpfile() callconv(.c) *c.FILE {
    @panic("tmpfile not implemented");
}

export fn tmpnam(s: [*]u8) callconv(.c) [*]u8 {
    _ = s;
    @panic("tmpnam not implemented");
}

export fn clearerr(stream: *c.FILE) callconv(.c) void {
    trace.log("clearerr {*}", .{stream});
    stream.errno = 0;
}

export fn setvbuf(stream: *c.FILE, buf: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int {
    _ = stream;
    _ = buf;
    _ = mode;
    _ = size;
    @panic("setvbuf not implemented");
}

export fn ferror(stream: *c.FILE) callconv(.c) c_int {
    trace.log("ferror {*} return {}", .{ stream, stream.errno });
    return stream.errno;
}

export fn perror(s: [*:0]const u8) callconv(.c) void {
    trace.log("perror {f}", .{trace.fmtStr(s)});
    @panic("perror not implemented");
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
    _ = x;
    @panic("acos not implemented");
}

export fn asin(x: f64) callconv(.c) f64 {
    _ = x;
    @panic("asin not implemented");
}

export fn atan(x: f64) callconv(.c) f64 {
    _ = x;
    @panic("atan not implemented");
}

export fn atan2(y: f64, x: f64) callconv(.c) f64 {
    _ = y;
    _ = x;
    @panic("atan2 not implemented");
}

// cos/sin are already defined somewhere in the libraries Zig includes
// on linux, not sure what library though or how

export fn tan(x: f64) callconv(.c) f64 {
    _ = x;
    @panic("tan not implemented");
}

export fn frexp(value: f32, exp: *c_int) callconv(.c) f64 {
    // TODO: look into error handling to match C spec
    const result = std.math.frexp(value);
    exp.* = result.exponent;
    return result.significand;
}

export fn ldexp(x: f64, exp: c_int) callconv(.c) f64 {
    // TODO: look into error handling to match C spec
    return std.math.ldexp(x, @as(i32, @intCast(exp)));
}

export fn pow(x: f64, y: f64) callconv(.c) f64 {
    // TODO: look into error handling to match C spec
    return std.math.pow(f64, x, y);
}

// --------------------------------------------------------------------------------
// locale
// --------------------------------------------------------------------------------
export fn setlocale(category: c_int, locale: [*:0]const u8) callconv(.c) [*:0]u8 {
    _ = category;
    _ = locale;
    @panic("setlocale not implemented");
}

export fn localeconv() callconv(.c) *c.lconv {
    trace.log("localeconv", .{});
    return &global.localeconv;
}

// --------------------------------------------------------------------------------
// time
// --------------------------------------------------------------------------------
export fn clock() callconv(.c) c.clock_t {
    @panic("clock not implemented");
}

export fn difftime(time1: c.time_t, time0: c.time_t) callconv(.c) f64 {
    _ = time1;
    _ = time0;
    @panic("difftime not implemented");
}

export fn mktime(timeptr: *c.tm) callconv(.c) c.time_t {
    _ = timeptr;
    @panic("mktime not implemented");
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

export fn gmtime(timer: *c.time_t) callconv(.c) *c.tm {
    _ = timer;
    @panic("gmtime not implemented");
}

export fn localtime(timer: *const c.time_t) callconv(.c) *c.tm {
    _ = timer;
    @panic("localtime not implemented");
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

export fn isspace(char: c_int) callconv(.c) c_int {
    trace.log("isspace {}", .{char});
    return @intFromBool(std.ascii.isWhitespace(std.math.cast(u8, char) orelse return 0));
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
    @panic("setjmp not implemented on this platform yet");
}
fn longjmp_fallback(env: c.jmp_buf, val: c_int) callconv(.c) noreturn {
    _ = env;
    _ = val;
    @panic("longjmp not implemented on this platform yet");
}
comptime {
    if (has_x86_64_setjmp_asm) {
        @export(&setjmp_x86_64, .{ .name = "setjmp" });
        @export(&setjmp_x86_64, .{ .name = "_setjmp" });
        @export(&setjmp_x86_64, .{ .name = "__setjmp" });

        @export(&longjmp_x86_64, .{ .name = "longjmp" });
        @export(&longjmp_x86_64, .{ .name = "_longjmp" });
    } else if (has_aarch64_setjmp_asm) {
        @export(&setjmp_aarch64, .{ .name = "setjmp" });
        @export(&setjmp_aarch64, .{ .name = "_setjmp" });
        @export(&setjmp_aarch64, .{ .name = "__setjmp" });

        @export(&longjmp_aarch64, .{ .name = "longjmp" });
        @export(&longjmp_aarch64, .{ .name = "_longjmp" });
    } else {
        @export(&setjmp_fallback, .{ .name = "setjmp" });
        @export(&setjmp_fallback, .{ .name = "_setjmp" });
        @export(&setjmp_fallback, .{ .name = "__setjmp" });

        @export(&longjmp_fallback, .{ .name = "longjmp" });
        @export(&longjmp_fallback, .{ .name = "_longjmp" });
    }
}
