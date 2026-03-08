/// Run the given program in a clean directory.
const builtin = @import("builtin");
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var temp_counter: usize = 0;

const ExternalRunner = enum {
    none,
    darling,
    wine,
};

fn externalRunnerFromEnv() ExternalRunner {
    // The build harness sets this only when the child binary must run under
    // Darling/Wine. Native runs leave it unset so the helper uses plain host
    // process execution with no emulator path rewriting.
    const value = std.process.getEnvVarOwned(arena.allocator(), "ZIGLIBC_EXTERNAL_RUNNER") catch return .none;
    if (std.mem.eql(u8, value, "darling")) return .darling;
    if (std.mem.eql(u8, value, "wine")) return .wine;
    return .none;
}

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

fn normalizeProgramPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.getCwdAlloc(allocator);
        return windowsPathAlloc(allocator, cwd, path);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(allocator, path);
    }
    return std.fs.realpathAlloc(allocator, path);
}

fn normalizeChildCwd(allocator: std.mem.Allocator, dirname: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.getCwdAlloc(allocator);
        return windowsPathAlloc(allocator, cwd, dirname);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(allocator, dirname);
    }
    return std.fs.cwd().realpathAlloc(allocator, dirname);
}

fn mapExistingPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    std.fs.cwd().access(path_no_dot, .{}) catch return allocator.dupe(u8, path);
    return std.fs.realpathAlloc(allocator, path_no_dot);
}

fn winePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(allocator, "Z:{s}", .{path});
    for (out) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    return out;
}

fn initForeignRunnerChild(
    allocator: std.mem.Allocator,
    runner: ExternalRunner,
    program_path: []const u8,
    args: []const []const u8,
) !std.process.Child {
    const abs_program = try std.fs.realpathAlloc(allocator, program_path);
    var mapped_args = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        mapped_args[i] = try mapExistingPathAlloc(allocator, arg);
    }

    var child_args = try allocator.alloc([]const u8, args.len + 2);
    child_args[0] = switch (runner) {
        .darling => "darling",
        .wine => "wine",
        .none => unreachable,
    };
    child_args[1] = switch (runner) {
        .darling => abs_program,
        .wine => try winePathAlloc(allocator, abs_program),
        .none => unreachable,
    };
    for (mapped_args, 0..) |arg, i| {
        child_args[i + 2] = switch (runner) {
            .darling => arg,
            .wine => blk: {
                std.fs.cwd().access(if (std.mem.startsWith(u8, arg, "./")) arg[2..] else arg, .{}) catch break :blk arg;
                break :blk try winePathAlloc(allocator, arg);
            },
            .none => unreachable,
        };
    }

    var child = std.process.Child.init(child_args, allocator);
    if (runner == .wine) {
        const env_map = try allocator.create(std.process.EnvMap);
        env_map.* = try std.process.getEnvMap(allocator);
        if (env_map.get("WINEDEBUG") == null) {
            try env_map.put("WINEDEBUG", "-all");
        }
        child.env_map = env_map;
    }
    return child;
}

pub fn main() !u8 {
    const allocator = arena.allocator();
    const full_args = try std.process.argsAlloc(allocator);
    if (full_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: testenv PROGRAM ARGS...\n");
        return 1;
    }

    const runner = externalRunnerFromEnv();
    const args = full_args[1..];
    var child = switch (runner) {
        .none => blk: {
            var child_args = try allocator.alloc([]const u8, args.len);
            @memcpy(child_args, args);
            child_args[0] = try normalizeProgramPath(allocator, args[0]);
            break :blk std.process.Child.init(child_args, allocator);
        },
        .darling, .wine => try initForeignRunnerChild(allocator, runner, args[0], args[1..]),
    };

    const dirname = blk: {
        const base = std.fs.path.basename(args[0]);
        var attempt: usize = 0;
        while (attempt < 64) : (attempt += 1) {
            const id = @atomicRmw(usize, &temp_counter, .Add, 1, .seq_cst);
            const candidate = try std.fmt.allocPrint(
                allocator,
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

    child.cwd = switch (runner) {
        .none => normalizeChildCwd(allocator, dirname) catch |err| {
            std.log.err("failed to normalize child cwd: {}", .{err});
            return err;
        },
        .darling, .wine => std.fs.cwd().realpathAlloc(allocator, dirname) catch |err| {
            std.log.err("realpath(cwd) failed: {}", .{err});
            return err;
        },
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
