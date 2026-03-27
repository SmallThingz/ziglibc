const std = @import("std");
const GitRepoStep = @import("../tools/GitRepoStep.zig");

const BusyboxPrepStep = struct {
    step: std.Build.Step,
    builder: *std.Build,
    repo_path: []const u8,
    pub fn create(b: *std.Build, repo: *GitRepoStep) *BusyboxPrepStep {
        const result = b.allocator.create(BusyboxPrepStep) catch unreachable;
        result.* = BusyboxPrepStep{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "busybox prep",
                .owner = b,
                .makeFn = make,
            }),
            .builder = b,
            .repo_path = repo.path,
        };
        result.*.step.dependOn(&repo.step);
        return result;
    }
    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *BusyboxPrepStep = @fieldParentPtr("step", step);
        const b = self.builder;
        const io = b.graph.io;

        var src_dir = try std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ b.build_root.path.?, "busybox" }), .{});
        defer src_dir.close(io);
        var dst_dir = try std.Io.Dir.cwd().openDir(io, self.repo_path, .{});
        defer dst_dir.close(io);
        try src_dir.copyFile("busybox_1_35_0.config", dst_dir, ".config", io, .{});
    }
};

pub fn add(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        .url = "https://git.busybox.net/busybox",
        .sha = "e512aeb0fb3c585948ae6517cfdf4a53cf99774d",
        .branch = null,
    });

    const prep = BusyboxPrepStep.create(b, repo);

    const exe = addExecutableCompat(b, .{
        .name = "busybox",
        .target = target,
        .optimize = optimize,
    });
    const install = b.addInstallArtifact(exe, .{});
    exe.step.dependOn(&prep.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        "editors/sed.c",
    };
    for (sources) |src| {
        files.append(b.pathJoin(&.{ repo_path, src })) catch unreachable;
    }
    addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
        "-std=c99",
    });
    addIncludePathCompat(exe, lazyPath(b, b.pathJoin(&.{ repo_path, "include" })));

    addIncludePathCompat(exe, lazyPath(b, "inc/libc"));
    addIncludePathCompat(exe, lazyPath(b, "inc/posix"));
    addIncludePathCompat(exe, lazyPath(b, "inc/linux"));
    linkLibraryCompat(exe, libc_only_std_static);
    //linkLibraryCompat(exe, zig_start);
    linkLibraryCompat(exe, zig_posix);
    // Static helper libraries do not currently propagate system-library
    // dependencies for downstream executables.
    if (target.result.os.tag == .windows) {
        linkSystemLibraryCompat(exe, "ntdll");
        linkSystemLibraryCompat(exe, "kernel32");
    }

    const step = b.step("busybox", "build busybox and it's applets");
    step.dependOn(&install.step);

    return exe;
}

fn addExecutableCompat(
    b: *std.Build,
    opt: struct {
        name: []const u8,
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
    },
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = opt.name,
        .root_module = b.createModule(.{
            .target = opt.target orelse b.graph.host,
            .optimize = opt.optimize orelse .Debug,
        }),
    });
}

fn addCSourceFilesCompat(
    step: *std.Build.Step.Compile,
    files: []const []const u8,
    flags: []const []const u8,
) void {
    for (files) |file| {
        addCSourceFileCompat(step, .{
            .file = lazyPath(step.step.owner, file),
            .flags = flags,
        });
    }
}

fn addCSourceFileCompat(step: *std.Build.Step.Compile, source: std.Build.Module.CSourceFile) void {
    step.root_module.addCSourceFile(source);
}

fn addIncludePathCompat(step: *std.Build.Step.Compile, path: std.Build.LazyPath) void {
    step.root_module.addIncludePath(path);
}

fn linkLibraryCompat(step: *std.Build.Step.Compile, lib: *std.Build.Step.Compile) void {
    step.root_module.linkLibrary(lib);
}

fn linkSystemLibraryCompat(step: *std.Build.Step.Compile, name: []const u8) void {
    step.root_module.linkSystemLibrary(name, .{});
}

fn lazyPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path))
        .{ .cwd_relative = path }
    else
        b.path(path);
}
