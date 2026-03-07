const builtin = @import("builtin");
const std = @import("std");

const c = @cImport({
    @cInclude("errno.h");
});

const windows = std.os.windows;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;

const Entry = struct {
    used: bool = false,
    handle: ?windows.HANDLE = null,
};

const max_extra_fds = 256;

var mutex: std.Thread.Mutex = .{};
var entries: [max_extra_fds]Entry = [_]Entry{.{}} ** max_extra_fds;
var stdio_closed: [3]bool = [_]bool{false} ** 3;

fn errnoConst(comptime name: []const u8, fallback: c_int) c_int {
    if (@hasDecl(c, name)) return @field(c, name);
    return fallback;
}

pub fn errnoFromWin32(err: windows.Win32Error) c_int {
    return switch (err) {
        .SUCCESS => 0,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .INVALID_NAME => c.ENOENT,
        .ACCESS_DENIED, .SHARING_VIOLATION, .LOCK_VIOLATION => c.EACCES,
        .FILE_EXISTS, .ALREADY_EXISTS => c.EEXIST,
        .INVALID_HANDLE => errnoConst("EBADF", c.EINVAL),
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => c.ENOMEM,
        .TOO_MANY_OPEN_FILES => errnoConst("EMFILE", c.ENOMEM),
        .WRITE_PROTECT => errnoConst("EROFS", c.EACCES),
        .DIRECTORY => errnoConst("EISDIR", c.EINVAL),
        .BROKEN_PIPE, .HANDLE_EOF => 0,
        else => errnoConst("EIO", c.EINVAL),
    };
}

fn stdHandleForFdLocked(fd: c_int) ?windows.HANDLE {
    if (fd < 0 or fd > 2) return null;
    if (stdio_closed[@as(usize, @intCast(fd))]) return null;
    const process_params = windows.peb().ProcessParameters;
    return switch (fd) {
        0 => process_params.hStdInput,
        1 => process_params.hStdOutput,
        2 => process_params.hStdError,
        else => null,
    };
}

fn handleFromFdLocked(fd: c_int) ?windows.HANDLE {
    if (fd >= 0 and fd <= 2) return stdHandleForFdLocked(fd);
    const index = fd - 3;
    if (index < 0 or index >= max_extra_fds) return null;
    const entry = entries[@as(usize, @intCast(index))];
    if (!entry.used) return null;
    return entry.handle;
}

pub fn handleFromFd(fd: c_int) ?windows.HANDLE {
    if (comptime builtin.os.tag != .windows) return null;
    mutex.lock();
    defer mutex.unlock();
    return handleFromFdLocked(fd);
}

pub fn fdFromHandle(handle: windows.HANDLE) ?c_int {
    if (comptime builtin.os.tag != .windows) return null;
    mutex.lock();
    defer mutex.unlock();

    var fd: c_int = 0;
    while (fd < 3) : (fd += 1) {
        if (stdHandleForFdLocked(fd) == handle) return fd;
    }

    for (entries, 0..) |entry, i| {
        if (entry.used and entry.handle == handle) {
            return @as(c_int, @intCast(i + 3));
        }
    }
    return null;
}

pub fn allocHandle(handle: windows.HANDLE) error{TooManyFiles}!c_int {
    if (comptime builtin.os.tag != .windows) return error.TooManyFiles;
    mutex.lock();
    defer mutex.unlock();

    for (&entries, 0..) |*entry, i| {
        if (!entry.used) {
            entry.* = .{ .used = true, .handle = handle };
            return @as(c_int, @intCast(i + 3));
        }
    }
    return error.TooManyFiles;
}

pub fn closeFd(fd: c_int) c_int {
    if (comptime builtin.os.tag != .windows) return errnoConst("ENOSYS", c.EINVAL);
    mutex.lock();
    defer mutex.unlock();

    const handle = handleFromFdLocked(fd) orelse return errnoConst("EBADF", c.EINVAL);
    if (CloseHandle(handle) == 0) {
        return errnoFromWin32(windows.kernel32.GetLastError());
    }

    if (fd >= 0 and fd <= 2) {
        stdio_closed[@as(usize, @intCast(fd))] = true;
    } else {
        entries[@as(usize, @intCast(fd - 3))] = .{};
    }
    return 0;
}
