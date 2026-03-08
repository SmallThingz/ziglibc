/// Run the given program in a clean directory
const builtin = @import("builtin");
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var temp_counter: usize = 0;

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
    if (std.mem.startsWith(u8, path_no_dot, "/Volumes/SystemRoot/")) {
        return allocator.dupe(u8, path_no_dot);
    }
    if (path_no_dot.len > 0 and path_no_dot[0] == '/') {
        return std.fmt.allocPrint(allocator, "/Volumes/SystemRoot{s}", .{path_no_dot});
    }
    return allocator.dupe(u8, path_no_dot);
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn normalizeDarwinPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (std.mem.startsWith(u8, path_no_dot, "/Volumes/SystemRoot/")) {
        return allocator.dupe(u8, path_no_dot);
    }
    if (path_no_dot.len > 0 and path_no_dot[0] == '/') {
        // Darling exposes the Linux host filesystem under /Volumes/SystemRoot, but a
        // native macOS run needs the real absolute path untouched. Rewriting every
        // absolute path here regresses native CI with FileNotFound as soon as the
        // child executable or cwd lives outside Darling.
        if (pathExistsAbsolute(path_no_dot)) {
            return allocator.dupe(u8, path_no_dot);
        }
        return darlingPathAlloc(allocator, path_no_dot);
    }
    const abs = std.fs.realpathAlloc(allocator, path_no_dot) catch |err| {
        const mapped = try darlingPathAlloc(allocator, path_no_dot);
        if (pathExistsAbsolute(mapped)) return mapped;
        return err;
    };
    if (pathExistsAbsolute(abs)) return abs;

    const mapped_abs = try darlingPathAlloc(allocator, abs);
    if (pathExistsAbsolute(mapped_abs)) return mapped_abs;
    return abs;
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
    } else if (builtin.os.tag.isDarwin()) {
        child_args[0] = normalizeDarwinPathAlloc(arena.allocator(), args[0]) catch |err| {
            std.log.err("failed to normalize darwin program path: {}", .{err});
            return err;
        };
    } else {
        child_args[0] = std.fs.realpathAlloc(arena.allocator(), args[0]) catch |err| {
            std.log.err("realpath(program) failed: {}", .{err});
            return err;
        };
    }

    const dirname = blk: {
        const base = std.fs.path.basename(args[0]);
        var attempt: usize = 0;
        while (attempt < 64) : (attempt += 1) {
            const id = @atomicRmw(usize, &temp_counter, .Add, 1, .seq_cst);
            const candidate = try std.fmt.allocPrint(
                arena.allocator(),
                "{s}-{d}-{x}-{x}.test.tmp",
                .{
                    base,
                    attempt,
                    @as(u64, @intCast(std.time.nanoTimestamp())),
                    id,
                },
            );
            std.fs.cwd().makeDir(candidate) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break :blk candidate;
        }
        return error.PathAlreadyExists;
    };
    defer std.fs.cwd().deleteTree(dirname) catch {};
    var child = std.process.Child.init(child_args, arena.allocator());
    child.cwd = if (builtin.os.tag == .windows) blk: {
        const cwd = try std.process.getCwdAlloc(arena.allocator());
        break :blk try windowsPathAlloc(arena.allocator(), cwd, dirname);
    } else if (builtin.os.tag.isDarwin()) blk: {
        break :blk normalizeDarwinPathAlloc(arena.allocator(), dirname) catch |err| {
            std.log.err("failed to normalize darwin cwd: {}", .{err});
            return err;
        };
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
    return 0;
}
