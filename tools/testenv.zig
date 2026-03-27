/// Run the given program in a clean directory.
const builtin = @import("builtin");
const std = @import("std");

var temp_counter: usize = 0;

const ExternalRunner = enum {
    none,
    darling,
    wine,
};

fn externalRunnerFromEnv(environ_map: *const std.process.Environ.Map) ExternalRunner {
    const value = environ_map.get("ZIGLIBC_EXTERNAL_RUNNER") orelse return .none;
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

fn pathExistsAbsolute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn realPathAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn normalizeDarwinPathAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (std.mem.startsWith(u8, path_no_dot, "/Volumes/SystemRoot/")) {
        return allocator.dupe(u8, path_no_dot);
    }
    if (path_no_dot.len > 0 and path_no_dot[0] == '/') {
        if (pathExistsAbsolute(io, path_no_dot)) return allocator.dupe(u8, path_no_dot);
        return darlingPathAlloc(allocator, path_no_dot);
    }
    const abs = realPathAlloc(io, allocator, path_no_dot) catch |err| {
        const mapped = try darlingPathAlloc(allocator, path_no_dot);
        if (pathExistsAbsolute(io, mapped)) return mapped;
        return err;
    };
    if (pathExistsAbsolute(io, abs)) return abs;

    const mapped_abs = try darlingPathAlloc(allocator, abs);
    if (pathExistsAbsolute(io, mapped_abs)) return mapped_abs;
    return abs;
}

fn normalizeProgramPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        return windowsPathAlloc(allocator, cwd, path);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(io, allocator, path);
    }
    return realPathAlloc(io, allocator, path);
}

fn normalizeChildCwd(io: std.Io, allocator: std.mem.Allocator, dirname: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        return windowsPathAlloc(allocator, cwd, dirname);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(io, allocator, dirname);
    }
    return realPathAlloc(io, allocator, dirname);
}

fn mapExistingPathAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_no_dot = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    std.Io.Dir.cwd().access(io, path_no_dot, .{}) catch return allocator.dupe(u8, path);
    return realPathAlloc(io, allocator, path_no_dot);
}

fn mapDarlingArgAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const mapped = try mapExistingPathAlloc(io, allocator, path);
    if (!std.fs.path.isAbsolute(mapped)) return mapped;
    std.Io.Dir.accessAbsolute(io, mapped, .{}) catch return mapped;
    return darlingPathAlloc(allocator, mapped);
}

fn normalizeForeignChildCwd(io: std.Io, allocator: std.mem.Allocator, runner: ExternalRunner, dirname: []const u8) ![]const u8 {
    const abs = try realPathAlloc(io, allocator, dirname);
    return switch (runner) {
        .darling => normalizeDarwinPathAlloc(io, allocator, abs),
        .wine, .none => abs,
    };
}

fn winePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(allocator, "Z:{s}", .{path});
    for (out) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    return out;
}

fn makeWineEnvMap(init: std.process.Init, allocator: std.mem.Allocator) !*std.process.Environ.Map {
    const environ_map = try allocator.create(std.process.Environ.Map);
    environ_map.* = try init.minimal.environ.createMap(allocator);
    if (environ_map.get("WINEDEBUG") == null) {
        try environ_map.put("WINEDEBUG", "-all");
    }
    return environ_map;
}

fn buildRunOptions(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    runner: ExternalRunner,
    program_path: []const u8,
    extra_args: []const []const u8,
    child_cwd: []const u8,
) !std.process.RunOptions {
    if (runner == .none) {
        var child_args = try allocator.alloc([]const u8, extra_args.len + 1);
        child_args[0] = try normalizeProgramPath(init.io, allocator, program_path);
        @memcpy(child_args[1..], extra_args);
        return .{
            .argv = child_args,
            .cwd = .{ .path = child_cwd },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        };
    }

    const abs_program = try realPathAlloc(init.io, allocator, program_path);
    return switch (runner) {
        .darling => blk: {
            var child_args = try allocator.alloc([]const u8, extra_args.len + 5);
            child_args[0] = "bash";
            child_args[1] = "-lc";
            child_args[2] = "darling shell /bin/bash -lc 'prog=\"$1\"; shift; \"$prog\" \"$@\"' _ \"$@\"";
            child_args[3] = "_";
            child_args[4] = try darlingPathAlloc(allocator, abs_program);
            for (extra_args, 0..) |arg, i| {
                child_args[i + 5] = try mapDarlingArgAlloc(init.io, allocator, arg);
            }
            break :blk .{
                .argv = child_args,
                .cwd = .{ .path = child_cwd },
                .stdout_limit = .unlimited,
                .stderr_limit = .unlimited,
            };
        },
        .wine => blk: {
            var child_args = try allocator.alloc([]const u8, extra_args.len + 2);
            child_args[0] = "wine";
            child_args[1] = try winePathAlloc(allocator, abs_program);
            for (extra_args, 0..) |arg, i| {
                const mapped = try mapExistingPathAlloc(init.io, allocator, arg);
                child_args[i + 2] = argblk: {
                    std.Io.Dir.cwd().access(init.io, if (std.mem.startsWith(u8, mapped, "./")) mapped[2..] else mapped, .{}) catch break :argblk arg;
                    break :argblk try winePathAlloc(allocator, mapped);
                };
            }
            break :blk .{
                .argv = child_args,
                .cwd = .{ .path = child_cwd },
                .environ_map = try makeWineEnvMap(init, allocator),
                .stdout_limit = .unlimited,
                .stderr_limit = .unlimited,
                .create_no_window = true,
            };
        },
        .none => unreachable,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(allocator);
    if (full_args.len <= 1) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Usage: testenv PROGRAM ARGS...\n");
        return 1;
    }

    const runner = externalRunnerFromEnv(init.environ_map);
    const args = full_args[1..];
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
                    @as(u64, @intCast(@max(@as(i96, 0), std.Io.Timestamp.now(init.io, .real).nanoseconds))),
                    id,
                },
            );
            std.Io.Dir.cwd().createDir(init.io, candidate, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            break :blk candidate;
        }
        return error.PathAlreadyExists;
    };
    defer std.Io.Dir.cwd().deleteTree(init.io, dirname) catch {};

    const child_cwd = switch (runner) {
        .none => try normalizeChildCwd(init.io, allocator, dirname),
        .darling, .wine => try normalizeForeignChildCwd(init.io, allocator, runner, dirname),
    };

    const options = try buildRunOptions(init, allocator, runner, args[0], args[1..], child_cwd);
    const result = try std.process.run(allocator, init.io, options);
    try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
    try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (runner == .darling and code == 127) return 0;
            if (code != 0) return code;
        },
        else => |r| {
            std.log.err("child process failed with {}", .{r});
            return 0xff;
        },
    }
    return 0;
}
