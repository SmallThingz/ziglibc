const std = @import("std");
const GitRepoStep = @import("../GitRepoStep.zig");

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

        std.log.warn("TODO: check config file timestamp to prevent unnecessary copy", .{});
        var src_dir = try std.fs.cwd().openDir(b.pathJoin(&.{ b.build_root.path.?, "busybox" }), .{});
        defer src_dir.close();
        var dst_dir = try std.fs.cwd().openDir(self.repo_path, .{});
        defer dst_dir.close();
        try src_dir.copyFile("busybox_1_35_0.config", dst_dir, ".config", .{});
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
    exe.addIncludePath(lazyPath(b, b.pathJoin(&.{ repo_path, "include" })));

    exe.addIncludePath(lazyPath(b, "inc/libc"));
    exe.addIncludePath(lazyPath(b, "inc/posix"));
    exe.addIncludePath(lazyPath(b, "inc/linux"));
    exe.linkLibrary(libc_only_std_static);
    //exe.linkLibrary(zig_start);
    exe.linkLibrary(zig_posix);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
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
        step.addCSourceFile(.{
            .file = lazyPath(step.step.owner, file),
            .flags = flags,
        });
    }
}

fn lazyPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path))
        .{ .cwd_relative = path }
    else
        b.path(path);
}
