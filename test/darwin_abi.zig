const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("signal.h");
    @cInclude("sys/select.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/time.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

fn abiMismatch(comptime name: []const u8, comptime got: usize, comptime expected: usize) noreturn {
    @compileError(std.fmt.comptimePrint("{s} ABI mismatch: got {d}, expected {d}", .{ name, got, expected }));
}

fn abiAlignMismatch(comptime name: []const u8, comptime got: usize, comptime expected: usize) noreturn {
    @compileError(std.fmt.comptimePrint("{s} ABI alignment mismatch: got {d}, expected {d}", .{ name, got, expected }));
}

fn expectAbi(comptime name: []const u8, comptime T: type, comptime U: type) void {
    if (@sizeOf(T) != @sizeOf(U)) abiMismatch(name, @sizeOf(T), @sizeOf(U));
    if (@alignOf(T) != @alignOf(U)) abiAlignMismatch(name, @alignOf(T), @alignOf(U));
}

comptime {
    if (!builtin.target.os.tag.isDarwin()) @compileError("darwin_abi.zig only applies to Darwin targets");

    // Native macOS is stricter than Darling about ABI drift. Keep these header
    // checks target-authentic for both Darwin architectures so Linux-hosted CI
    // fails at compile time before Apple Silicon finds the mismatch at runtime.
    expectAbi("sigset_t", c.sigset_t, std.c.sigset_t);
    expectAbi("struct sigaction", c.struct_sigaction, std.c.Sigaction);
    expectAbi("pthread_t", c.pthread_t, std.c.pthread_t);
    expectAbi("pthread_attr_t", c.pthread_attr_t, std.c.pthread_attr_t);
    expectAbi("pthread_mutex_t", c.pthread_mutex_t, std.c.pthread_mutex_t);
    expectAbi("pthread_cond_t", c.pthread_cond_t, std.c.pthread_cond_t);
    expectAbi("mode_t", c.mode_t, std.posix.mode_t);
    expectAbi("off_t", c.off_t, std.posix.off_t);
    expectAbi("time_t", c.time_t, std.posix.time_t);
    expectAbi("struct sockaddr", c.struct_sockaddr, std.posix.sockaddr);
}

pub fn main() void {}
