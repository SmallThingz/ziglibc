const builtin = @import("builtin");
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

fn externalRunnerFromEnv() ExternalRunner {
    // The build harness sets this only when the compared binaries themselves are
    // foreign-target artifacts. Keep emulator-specific argument/path handling out
    // of native parity runs entirely.
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

fn normalizedProgramPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const cwd = try std.process.getCwdAlloc(allocator);
        return windowsPathAlloc(allocator, cwd, path);
    }
    if (builtin.os.tag.isDarwin()) {
        return normalizeDarwinPathAlloc(allocator, path);
    }
    return std.fs.realpathAlloc(allocator, path);
}

fn normalizedChildCwd(allocator: std.mem.Allocator, dirname: []const u8) ![]const u8 {
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

fn termEqual(a: std.process.Child.Term, b: std.process.Child.Term) bool {
    return switch (a) {
        .Exited => |code| switch (b) {
            .Exited => |other| code == other,
            else => false,
        },
        .Signal => |sig| switch (b) {
            .Signal => |other| sig == other,
            else => false,
        },
        .Stopped => |sig| switch (b) {
            .Stopped => |other| sig == other,
            else => false,
        },
        .Unknown => |code| switch (b) {
            .Unknown => |other| code == other,
            else => false,
        },
    };
}

fn initChild(
    allocator: std.mem.Allocator,
    runner: ExternalRunner,
    program_path: []const u8,
    shared_args: []const []const u8,
) !std.process.Child {
    if (runner == .none) {
        const normalized_program = try normalizedProgramPath(allocator, program_path);
        var child_args = try allocator.alloc([]const u8, shared_args.len + 1);
        child_args[0] = normalized_program;
        @memcpy(child_args[1..], shared_args);
        return std.process.Child.init(child_args, allocator);
    }

    const abs_program = try std.fs.realpathAlloc(allocator, program_path);
    var child_args = try allocator.alloc([]const u8, shared_args.len + 2);
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
    for (shared_args, 0..) |arg, i| {
        const mapped = try mapExistingPathAlloc(allocator, arg);
        child_args[i + 2] = switch (runner) {
            .darling => mapped,
            .wine => blk: {
                std.fs.cwd().access(if (std.mem.startsWith(u8, mapped, "./")) mapped[2..] else mapped, .{}) catch break :blk arg;
                break :blk try winePathAlloc(allocator, mapped);
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

fn runProgram(
    allocator: std.mem.Allocator,
    runner: ExternalRunner,
    program_path: []const u8,
    label: []const u8,
    shared_args: []const []const u8,
) !RunResult {
    const dirname = try std.fmt.allocPrint(
        allocator,
        "{s}-{x}.parity.tmp",
        .{ label, @as(u64, @intCast(std.time.nanoTimestamp())) },
    );
    std.fs.cwd().deleteTree(dirname) catch {};
    try std.fs.cwd().makeDir(dirname);
    errdefer std.fs.cwd().deleteTree(dirname) catch {};

    var child = try initChild(allocator, runner, program_path, shared_args);
    child.cwd = switch (runner) {
        .none => try normalizedChildCwd(allocator, dirname),
        .darling, .wine => try std.fs.cwd().realpathAlloc(allocator, dirname),
    };
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout: std.ArrayList(u8) = .{};
    var stderr: std.ArrayList(u8) = .{};
    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    const term = try child.wait();

    std.fs.cwd().deleteTree(dirname) catch {};
    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = term,
    };
}

pub fn main() !u8 {
    const allocator = arena.allocator();
    const full_args = try std.process.argsAlloc(allocator);
    if (full_args.len < 3) {
        try std.fs.File.stderr().writeAll("Usage: parityenv EXPECTED_PROGRAM ACTUAL_PROGRAM [ARGS...]\n");
        return 1;
    }

    const runner = externalRunnerFromEnv();
    const expected = try runProgram(allocator, runner, full_args[1], "expected", full_args[3..]);
    const actual = try runProgram(allocator, runner, full_args[2], "actual", full_args[3..]);

    if (!std.mem.eql(u8, expected.stdout, actual.stdout)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "stdout mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected.stdout, actual.stdout },
        );
        try std.fs.File.stderr().writeAll(msg);
        return 1;
    }
    if (!std.mem.eql(u8, expected.stderr, actual.stderr)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "stderr mismatch\nexpected:\n{s}\nactual:\n{s}\n",
            .{ expected.stderr, actual.stderr },
        );
        try std.fs.File.stderr().writeAll(msg);
        return 1;
    }
    if (!termEqual(expected.term, actual.term)) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "exit mismatch\nexpected: {any}\nactual: {any}\n",
            .{ expected.term, actual.term },
        );
        try std.fs.File.stderr().writeAll(msg);
        return 1;
    }

    try std.fs.File.stdout().writeAll("Success!\n");
    return 0;
}
