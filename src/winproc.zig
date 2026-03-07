const builtin = @import("builtin");
const std = @import("std");
const winfd = @import("winfd.zig");

const c = @cImport({
    @cInclude("errno.h");
});

const windows = std.os.windows;

fn errnoConst(comptime name: []const u8, fallback: c_int) c_int {
    if (@hasDecl(c, name)) return @field(c, name);
    return fallback;
}

pub fn hasShell() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return true;
}

fn shellPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "COMSPEC") catch try allocator.dupe(u8, "cmd.exe");
}

fn shellCommandLineAllocZ(allocator: std.mem.Allocator, shell_path: []const u8, command: [*:0]const u8) ![:0]u16 {
    const command_line = try std.fmt.allocPrint(allocator, "\"{s}\" /c {s}", .{ shell_path, std.mem.span(command) });
    defer allocator.free(command_line);
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, command_line);
}

pub fn spawnShell(
    command: [*:0]const u8,
    stdin_handle: ?windows.HANDLE,
    stdout_handle: ?windows.HANDLE,
    stderr_handle: ?windows.HANDLE,
    inherit_handles: bool,
    err_out: *c_int,
) ?windows.HANDLE {
    if (comptime builtin.os.tag != .windows) {
        err_out.* = errnoConst("ENOSYS", c.EINVAL);
        return null;
    }

    const allocator = std.heap.page_allocator;
    const shell_path = shellPathAlloc(allocator) catch {
        err_out.* = c.ENOMEM;
        return null;
    };
    defer allocator.free(shell_path);

    const shell_path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, shell_path) catch {
        err_out.* = c.EINVAL;
        return null;
    };
    defer allocator.free(shell_path_w);

    const command_line_w = shellCommandLineAllocZ(allocator, shell_path, command) catch {
        err_out.* = c.EINVAL;
        return null;
    };
    defer allocator.free(command_line_w);

    const params = windows.peb().ProcessParameters;
    var startup = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    if (stdin_handle != null or stdout_handle != null or stderr_handle != null) {
        startup.dwFlags = windows.STARTF_USESTDHANDLES;
        startup.hStdInput = stdin_handle orelse params.hStdInput;
        startup.hStdOutput = stdout_handle orelse params.hStdOutput;
        startup.hStdError = stderr_handle orelse params.hStdError;
    }

    var process_info: windows.PROCESS_INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        shell_path_w.ptr,
        @ptrCast(command_line_w.ptr),
        null,
        null,
        @intFromBool(inherit_handles),
        .{},
        null,
        null,
        &startup,
        &process_info,
    ) == 0) {
        err_out.* = winfd.errnoFromWin32(windows.kernel32.GetLastError());
        return null;
    }

    _ = windows.kernel32.CloseHandle(process_info.hThread);
    return process_info.hProcess;
}

pub fn waitProcessStatus(process_handle: windows.HANDLE) c_int {
    if (comptime builtin.os.tag != .windows) return -1;

    windows.WaitForSingleObject(process_handle, windows.INFINITE) catch {
        c.errno = winfd.errnoFromWin32(windows.kernel32.GetLastError());
        _ = windows.kernel32.CloseHandle(process_handle);
        return -1;
    };

    var exit_code: windows.DWORD = 0;
    if (windows.kernel32.GetExitCodeProcess(process_handle, &exit_code) == 0) {
        c.errno = winfd.errnoFromWin32(windows.kernel32.GetLastError());
        _ = windows.kernel32.CloseHandle(process_handle);
        return -1;
    }

    _ = windows.kernel32.CloseHandle(process_handle);
    return @as(c_int, @intCast(exit_code)) << 8;
}
