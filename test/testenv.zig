/// Run the given program in a clean directory
const builtin = @import("builtin");
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn windowsPathAlloc(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    const out = if (path_no_dot.len >= 2 and path_no_dot[1] == ':')
        try allocator.dupe(u8, path_no_dot)
    else if (path_no_dot.len > 0 and path_no_dot[0] == '/')
        try std.fmt.allocPrint(allocator, "Z:{s}", .{path_no_dot})
    else
        try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ cwd, path_no_dot });
    for (out) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    return out;
}

fn darlingPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (path_no_dot.len > 0 and path_no_dot[0] == '/') {
        return std.fmt.allocPrint(allocator, "/Volumes/SystemRoot{s}", .{path_no_dot});
    }
    return allocator.dupe(u8, path_no_dot);
}

pub fn main() !u8 {
    const full_args = try std.process.argsAlloc(arena.allocator());
    if (full_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: testenv PROGRAM ARGS...\n");
        return 1;
    }
    const args = full_args[1..];
    var child_args = try arena.allocator().alloc([]const u8, args.len);
    @memcpy(child_args, args);
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.getCwdAlloc(arena.allocator());
        child_args[0] = try windowsPathAlloc(arena.allocator(), cwd, args[0]);
    } else {
        child_args[0] = std.fs.realpathAlloc(arena.allocator(), args[0]) catch |err| blk: {
            if (builtin.os.tag.isDarwin() and err == error.FileNotFound) {
                break :blk try darlingPathAlloc(arena.allocator(), args[0]);
            }
            std.log.err("realpath(program) failed: {}", .{err});
            return err;
        };
    }

    // TODO: improve this
    const dirname = try std.fmt.allocPrint(
        arena.allocator(),
        "{s}-{x}.test.tmp",
        .{ std.fs.path.basename(args[0]), @as(u64, @intCast(std.time.nanoTimestamp())) },
    );
    std.fs.cwd().deleteTree(dirname) catch {};
    try std.fs.cwd().makeDir(dirname);
    var child = std.process.Child.init(child_args, arena.allocator());
    child.cwd = if (builtin.os.tag == .windows) blk: {
        const cwd = try std.process.getCwdAlloc(arena.allocator());
        break :blk try windowsPathAlloc(arena.allocator(), cwd, dirname);
    } else std.fs.cwd().realpathAlloc(arena.allocator(), dirname) catch |err| {
        std.log.err("realpath(cwd) failed: {}", .{err});
        return err;
    };
    child.spawn() catch |err| {
        std.log.err("spawn failed: {}", .{err});
        return err;
    };
    const result = try child.wait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) return code;
        },
        else => |r| {
            std.log.err("child process failed with {}", .{r});
            return 0xff;
        },
    }
    std.fs.cwd().deleteTree(dirname) catch {};
    return 0;
}
