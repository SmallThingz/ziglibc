const builtin = @import("builtin");
const std = @import("std");

var temp_counter: usize = 0;

const ExternalRunner = enum {
    none,
    darling,
    wine,
};

const RunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
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

fn normalizedProgramPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        return windowsPathAlloc(allocator, cwd, path);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(io, allocator, path);
    }
    return realPathAlloc(io, allocator, path);
}

fn normalizedChildCwd(io: std.Io, allocator: std.mem.Allocator, dirname: []const u8) ![]const u8 {
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

fn termEqual(a: std.process.Child.Term, b: std.process.Child.Term) bool {
    return switch (a) {
        .exited => |code| switch (b) {
            .exited => |other| code == other,
            else => false,
        },
        .signal => |sig| switch (b) {
            .signal => |other| sig == other,
            else => false,
        },
        .stopped => |sig| switch (b) {
            .stopped => |other| sig == other,
            else => false,
        },
        .unknown => |code| switch (b) {
            .unknown => |other| code == other,
            else => false,
        },
    };
}

fn equalIgnoringCrlf(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and a[ai] == '\r') ai += 1;
        while (bi < b.len and b[bi] == '\r') bi += 1;
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (a[ai] != b[bi]) return false;
        ai += 1;
        bi += 1;
    }
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
    shared_args: []const []const u8,
    child_cwd: []const u8,
) !std.process.RunOptions {
    if (runner == .none) {
        const normalized_program = try normalizedProgramPath(init.io, allocator, program_path);
        var child_args = try allocator.alloc([]const u8, shared_args.len + 1);
        child_args[0] = normalized_program;
        @memcpy(child_args[1..], shared_args);
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
            var child_args = try allocator.alloc([]const u8, shared_args.len + 5);
            child_args[0] = "bash";
            child_args[1] = "-lc";
            child_args[2] = "darling shell /bin/bash -lc 'prog=\"$1\"; shift; \"$prog\" \"$@\"' _ \"$@\"";
            child_args[3] = "_";
            child_args[4] = try darlingPathAlloc(allocator, abs_program);
            for (shared_args, 0..) |arg, i| {
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
            var child_args = try allocator.alloc([]const u8, shared_args.len + 2);
            child_args[0] = "wine";
            child_args[1] = try winePathAlloc(allocator, abs_program);
            for (shared_args, 0..) |arg, i| {
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

fn runProgram(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    runner: ExternalRunner,
    program_path: []const u8,
    label: []const u8,
    shared_args: []const []const u8,
) !RunResult {
    const dirname = blk: {
        var attempt: usize = 0;
        while (attempt < 64) : (attempt += 1) {
            const id = @atomicRmw(usize, &temp_counter, .Add, 1, .seq_cst);
            const candidate = try std.fmt.allocPrint(
                allocator,
                "{s}-{d}-{x}-{x}.parity.tmp",
                .{
                    label,
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
    errdefer std.Io.Dir.cwd().deleteTree(init.io, dirname) catch {};

    const child_cwd = switch (runner) {
        .none => try normalizedChildCwd(init.io, allocator, dirname),
        .darling, .wine => try normalizeForeignChildCwd(init.io, allocator, runner, dirname),
    };
    const options = try buildRunOptions(init, allocator, runner, program_path, shared_args, child_cwd);
    const result = try std.process.run(allocator, init.io, options);

    std.Io.Dir.cwd().deleteTree(init.io, dirname) catch {};
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const full_args = try init.minimal.args.toSlice(allocator);
    if (full_args.len < 3) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Usage: parityenv EXPECTED_PROGRAM ACTUAL_PROGRAM [ARGS...]\n");
        return 1;
    }

    const runner = externalRunnerFromEnv(init.environ_map);
    const expected = try runProgram(init, allocator, runner, full_args[1], "expected", full_args[3..]);
    const actual = try runProgram(init, allocator, runner, full_args[2], "actual", full_args[3..]);

    if (!std.mem.eql(u8, expected.stdout, actual.stdout)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "stdout mismatch\nexpected stdout:\n{s}\nactual stdout:\n{s}\nexpected stderr:\n{s}\nactual stderr:\n{s}\nexpected term: {any}\nactual term: {any}\n",
            .{ expected.stdout, actual.stdout, expected.stderr, actual.stderr, expected.term, actual.term },
        );
        try std.Io.File.stderr().writeStreamingAll(init.io, msg);
        return 1;
    }
    if (!equalIgnoringCrlf(expected.stderr, actual.stderr)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "stderr mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected.stderr, actual.stderr },
        );
        try std.Io.File.stderr().writeStreamingAll(init.io, msg);
        return 1;
    }
    if (!termEqual(expected.term, actual.term)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "exit mismatch\nexpected: {any}\nactual: {any}\n",
            .{ expected.term, actual.term },
        );
        try std.Io.File.stderr().writeStreamingAll(init.io, msg);
        return 1;
    }

    try std.Io.File.stdout().writeStreamingAll(init.io, "Success!\n");
    return 0;
}
