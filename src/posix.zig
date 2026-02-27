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

const darwin = if (builtin.os.tag.isDarwin()) struct {
    const mach_port_t = c_uint;
    const clock_serv_t = mach_port_t;
    const kern_return_t = c_int;
    const mach_timespec_t = extern struct {
        sec: c_uint,
        nsec: c_int,
    };
    const CALENDAR_CLOCK: c_int = 1;

    extern "c" fn mach_host_self() mach_port_t;
    extern "c" fn mach_port_deallocate(task: mach_port_t, name: mach_port_t) kern_return_t;
    extern "c" fn clock_get_time(clock_serv: clock_serv_t, cur_time: *mach_timespec_t) kern_return_t;
    extern "c" fn host_get_clock_service(
        host: mach_port_t,
        clock_id: c_int,
        clock_serv: *clock_serv_t,
    ) kern_return_t;
} else struct {};

const darwin_syscall = if (builtin.os.tag.isDarwin()) struct {
    // Stable BSD syscall numbers used by Darwin's syscall(2) ABI.
    const read: c_long = 3;
    const write: c_long = 4;
    const open: c_long = 5;
} else struct {};

// C ABI globals: `extern char *optarg; extern int opterr, optind, optopt;`
export var optarg: [*c]u8 = null;
export var opterr: c_int = 1;
export var optind: c_int = 1;
export var optopt: c_int = 0;

/// Returns some information through these globals
///    extern char *optarg;
///    extern int opterr, optind, optopt;
export fn getopt(argc: c_int, argv: [*][*:0]u8, optstring: [*:0]const u8) callconv(.c) c_int {
    optarg = null;
    if (optind < 1) optind = 1;
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
    const arg = argv[@as(usize, @intCast(optind))];
    if (arg[0] != '-' or arg[1] == 0) {
        // Stop option parsing when we reach a non-option argument.
        return -1;
    }
    if (arg[1] == '-' and arg[2] == 0) {
        // End-of-options marker.
        optind += 1;
        return -1;
    }
    const result = c.strchr(optstring, arg[1]) orelse {
        optind += 1;
        optopt = @as(c_int, arg[1]);
        return '?';
    };
    optind += 1;

    if (arg[2] != 0) {
        // Support compact required argument form: -ovalue
        if (result[1] == ':') {
            optarg = @ptrCast(arg + 2);
            return @as(c_int, arg[1]);
        }
        @panic("multi-letter argument not implemented");
    }

    const takes_arg = result[1] == ':';
    if (takes_arg) {
        const is_optional = result[2] == ':';
        if (is_optional) @panic("optional args not implemented");
        if (optind >= argc) {
            optopt = @as(c_int, arg[1]);
            return if (optstring[0] == ':') ':' else '?';
        }
        optarg = @ptrCast(argv[@as(usize, @intCast(optind))]);
        optind += 1;
    }
    return @as(c_int, arg[1]);
}

fn zwriteRaw(fd: c_int, buf: [*]const u8, nbyte: usize) isize {
    if (builtin.os.tag.isDarwin()) {
        const rc = syscall(darwin_syscall.write, fd, buf, nbyte);
        return if (rc == -1) -1 else @as(isize, @intCast(rc));
    }
    if (builtin.os.tag == .windows) {
        @panic("write not implemented on windows");
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
        @panic("read not implemented on windows");
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
        @panic("open not implemented on windows");
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

export fn _zopen(path: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.c) c_int {
    return zopenRaw(path, oflag, mode);
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
        @panic("mkostemp not implemented in Windows");
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
    @panic("fileno not implemented");
}

export fn popen(command: [*:0]const u8, mode: [*:0]const u8) callconv(.c) *c.FILE {
    trace.log("popen '{f}' mode='{s}'", .{ trace.fmtStr(command), mode });
    @panic("popen not implemented");
}
export fn pclose(stream: *c.FILE) callconv(.c) c_int {
    _ = stream;
    @panic("pclose not implemented");
}

export fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*c.FILE {
    trace.log("fdopen {d} mode={s}", .{ fd, mode });
    if (builtin.os.tag == .windows) @panic("not impl");

    const file = cstd.__zreserveFile() orelse {
        c.errno = c.ENOMEM;
        return null;
    };
    file.fd = fd;
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
    @panic("acces not implemented");
}

export fn unlink(path: [*:0]const u8) callconv(.c) c_int {
    if (builtin.os.tag == .windows)
        @panic("windows unlink not implemented");

    switch (os.errno(os.system.unlink(path))) {
        .SUCCESS => return 0,
        else => |e| {
            c.errno = @intFromEnum(e);
            return -1;
        },
    }
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
    if (builtin.os.tag == .windows)
        @panic("isatty not supported on windows (yet?)");

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
        if (clk_id != c.CLOCK_REALTIME) {
            c.errno = c.EINVAL;
            return -1;
        }
        const host = darwin.mach_host_self();
        var clock_serv: darwin.clock_serv_t = 0;
        if (darwin.host_get_clock_service(host, darwin.CALENDAR_CLOCK, &clock_serv) != 0) {
            c.errno = c.EINVAL;
            return -1;
        }
        defer _ = darwin.mach_port_deallocate(host, clock_serv);

        var now: darwin.mach_timespec_t = undefined;
        if (darwin.clock_get_time(clock_serv, &now) != 0) {
            c.errno = c.EINVAL;
            return -1;
        }
        setTimespec(tp, now.sec, now.nsec);
        return 0;
    }

    if (builtin.os.tag == .windows) {
        if (clk_id == c.CLOCK_REALTIME) {
            const ns = std.time.nanoTimestamp();
            const sec = @divFloor(ns, std.time.ns_per_s);
            const nsec = @mod(ns, std.time.ns_per_s);
            setTimespec(tp, sec, nsec);
            return 0;
        }
        // TODO POSIX implementation of CLOCK.MONOTONIC on Windows.
        std.debug.panic("clk_id {} not implemented on Windows", .{clk_id});
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
    @panic("gettimeofday not implemented");
}

export fn setitimer(which: c_int, value: *const c.itimerval, avalue: *c.itimerval) callconv(.c) c_int {
    trace.log("setitimer which={}", .{which});
    _ = value;
    _ = avalue;
    @panic("setitimer not implemented");
}

// --------------------------------------------------------------------------------
// signal
// --------------------------------------------------------------------------------
export fn sigaction(sig: c_int, act: *const c.struct_sigaction, oact: *c.struct_sigaction) callconv(.c) c_int {
    trace.log("sigaction sig={}", .{sig});
    _ = act;
    _ = oact;
    @panic("sigaction not implemented");
}

// --------------------------------------------------------------------------------
// sys/stat.h
// --------------------------------------------------------------------------------
export fn chmod(path: [*:0]const u8, mode: c.mode_t) callconv(.c) c_int {
    trace.log("chmod '{s}' mode=0x{x}", .{ path, mode });
    @panic("chmod not implemented");
}

export fn fstat(fd: c_int, buf: *c.struct_stat) c_int {
    _ = fd;
    _ = buf;
    @panic("fstat not implemented");
}

export fn umask(mode: c.mode_t) callconv(.c) c.mode_t {
    trace.log("umask 0x{x}", .{mode});
    const old_mode = std.os.linux.syscall1(.umask, @as(usize, @intCast(mode)));
    switch (os.errno(old_mode)) {
        .SUCCESS => {},
        else => |e| std.debug.panic("umask syscall should never fail but got '{s}'", .{@tagName(e)}),
    }
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
    @panic("not impl");
    //    var a_next = a;
    //    var b_next = b;
    //    while (a_next[0] == b_next[0] and a_next[0] != 0) {
    //        a_next += 1;
    //        b_next += 1;
    //    }
    //    const result = @intCast(c_int, a_next[0]) -| @intCast(c_int, b_next[0]);
    //    trace.log("strcmp return {}", .{result});
    //    return result;
}

// --------------------------------------------------------------------------------
// sys/ioctl
// --------------------------------------------------------------------------------
export fn _ioctlArgPtr(fd: c_int, request: c_ulong, arg_ptr: *anyopaque) c_int {
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
    @panic("TODO: implement select");
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
