const builtin = @import("builtin");
const std = @import("std");
const compat = @import("head_compat.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
});

const windows = std.os.windows;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: windows.HANDLE,
    hSourceHandle: windows.HANDLE,
    hTargetProcessHandle: windows.HANDLE,
    lpTargetHandle: *windows.HANDLE,
    dwDesiredAccess: u32,
    bInheritHandle: windows.BOOL,
    dwOptions: u32,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: u32,
    dwFlags: u32,
) callconv(.winapi) windows.BOOL;

const Entry = struct {
    used: bool = false,
    handle: ?windows.HANDLE = null,
    status_flags: c_int = 0,
    fd_flags: c_int = 0,
};

const max_extra_fds = 256;
const handle_flag_inherit = 0x0000_0001;
const duplicate_same_access = 0x0000_0002;

var mutex: compat.Mutex = .{};
var entries: [max_extra_fds]Entry = [_]Entry{.{}} ** max_extra_fds;
var stdio_closed: [3]bool = [_]bool{false} ** 3;
var stdio_status_flags: [3]c_int = .{ c.O_RDONLY, c.O_WRONLY, c.O_WRONLY };
var stdio_fd_flags: [3]c_int = [_]c_int{0} ** 3;

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

fn entryForFdLocked(fd: c_int) ?*Entry {
    if (fd < 3) return null;
    const index = fd - 3;
    if (index < 0 or index >= max_extra_fds) return null;
    const entry = &entries[@as(usize, @intCast(index))];
    if (!entry.used) return null;
    return entry;
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

fn allocHandleLocked(handle: windows.HANDLE, min_fd: c_int, status_flags: c_int, fd_flags: c_int) error{TooManyFiles}!c_int {
    const start_index: usize = if (min_fd <= 3) 0 else @intCast(min_fd - 3);
    var i: usize = start_index;
    while (i < entries.len) : (i += 1) {
        const entry = &entries[i];
        if (!entry.used) {
            entry.* = .{
                .used = true,
                .handle = handle,
                .status_flags = status_flags,
                .fd_flags = fd_flags,
            };
            return @as(c_int, @intCast(i + 3));
        }
    }
    return error.TooManyFiles;
}

pub fn allocHandleFlags(handle: windows.HANDLE, status_flags: c_int, fd_flags: c_int) error{TooManyFiles}!c_int {
    if (comptime builtin.os.tag != .windows) return error.TooManyFiles;
    mutex.lock();
    defer mutex.unlock();
    return allocHandleLocked(handle, 3, status_flags, fd_flags);
}

pub fn allocHandle(handle: windows.HANDLE) error{TooManyFiles}!c_int {
    return allocHandleFlags(handle, 0, 0);
}

pub fn getStatusFlags(fd: c_int) ?c_int {
    if (comptime builtin.os.tag != .windows) return null;
    mutex.lock();
    defer mutex.unlock();
    if (fd >= 0 and fd <= 2) {
        if (stdio_closed[@as(usize, @intCast(fd))]) return null;
        return stdio_status_flags[@as(usize, @intCast(fd))];
    }
    const entry = entryForFdLocked(fd) orelse return null;
    return entry.status_flags;
}

pub fn setStatusFlags(fd: c_int, status_flags: c_int) bool {
    if (comptime builtin.os.tag != .windows) return false;
    mutex.lock();
    defer mutex.unlock();
    if (fd >= 0 and fd <= 2) {
        if (stdio_closed[@as(usize, @intCast(fd))]) return false;
        stdio_status_flags[@as(usize, @intCast(fd))] = status_flags;
        return true;
    }
    const entry = entryForFdLocked(fd) orelse return false;
    entry.status_flags = status_flags;
    return true;
}

pub fn getFdFlags(fd: c_int) ?c_int {
    if (comptime builtin.os.tag != .windows) return null;
    mutex.lock();
    defer mutex.unlock();
    if (fd >= 0 and fd <= 2) {
        if (stdio_closed[@as(usize, @intCast(fd))]) return null;
        return stdio_fd_flags[@as(usize, @intCast(fd))];
    }
    const entry = entryForFdLocked(fd) orelse return null;
    return entry.fd_flags;
}

pub fn setFdFlags(fd: c_int, fd_flags: c_int) c_int {
    if (comptime builtin.os.tag != .windows) return errnoConst("ENOSYS", c.EINVAL);
    mutex.lock();
    defer mutex.unlock();

    const handle = handleFromFdLocked(fd) orelse return errnoConst("EBADF", c.EINVAL);
    const inherit: u32 = if ((fd_flags & c.FD_CLOEXEC) != 0) 0 else handle_flag_inherit;
    if (SetHandleInformation(handle, handle_flag_inherit, inherit) == 0) {
        return errnoFromWin32(windows.GetLastError());
    }

    if (fd >= 0 and fd <= 2) {
        if (stdio_closed[@as(usize, @intCast(fd))]) return errnoConst("EBADF", c.EINVAL);
        stdio_fd_flags[@as(usize, @intCast(fd))] = fd_flags & c.FD_CLOEXEC;
        return 0;
    }
    const entry = entryForFdLocked(fd) orelse return errnoConst("EBADF", c.EINVAL);
    entry.fd_flags = fd_flags & c.FD_CLOEXEC;
    return 0;
}

pub fn dupFd(fd: c_int, min_fd: c_int) c_int {
    if (comptime builtin.os.tag != .windows) return -errnoConst("ENOSYS", c.EINVAL);
    mutex.lock();
    defer mutex.unlock();

    const handle = handleFromFdLocked(fd) orelse return -errnoConst("EBADF", c.EINVAL);
    var new_handle: windows.HANDLE = undefined;
    if (DuplicateHandle(
        GetCurrentProcess(),
        handle,
        GetCurrentProcess(),
        &new_handle,
        0,
        0,
        duplicate_same_access,
    ) == 0) {
        return -errnoFromWin32(windows.GetLastError());
    }

    const status_flags = if (fd >= 0 and fd <= 2)
        stdio_status_flags[@as(usize, @intCast(fd))]
    else
        (entryForFdLocked(fd) orelse unreachable).status_flags;
    const fd_flags = if (fd >= 0 and fd <= 2)
        stdio_fd_flags[@as(usize, @intCast(fd))]
    else
        (entryForFdLocked(fd) orelse unreachable).fd_flags;

    return allocHandleLocked(new_handle, @max(min_fd, 3), status_flags, fd_flags) catch {
        _ = CloseHandle(new_handle);
        return -errnoConst("EMFILE", c.ENOMEM);
    };
}

pub fn closeFd(fd: c_int) c_int {
    if (comptime builtin.os.tag != .windows) return errnoConst("ENOSYS", c.EINVAL);
    mutex.lock();
    defer mutex.unlock();

    const handle = handleFromFdLocked(fd) orelse return errnoConst("EBADF", c.EINVAL);
    if (CloseHandle(handle) == 0) {
        return errnoFromWin32(windows.GetLastError());
    }

    if (fd >= 0 and fd <= 2) {
        stdio_closed[@as(usize, @intCast(fd))] = true;
    } else {
        entries[@as(usize, @intCast(fd - 3))] = .{};
    }
    return 0;
}
