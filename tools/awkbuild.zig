const std = @import("std");
const GitRepoStep = @import("../GitRepoStep.zig");

pub fn addAwk(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/onetrueawk/awk",
        .sha = "9e248c317b88470fc86aa7c988919dc49452c88c",
        .branch = null,
    });

    //    const config_step = b.addWriteFile(
    //        b.pathJoin(&.{repo.path, "src", "config.h"}),
    //        "#define VERSION \"1.0\"",
    //    );
    //    config_step.step.dependOn(&repo.step);

    const exe = addExecutableCompat(b, .{
        .name = "awk",
        .target = target,
        .optimize = optimize,
    });
    const install = b.addInstallArtifact(exe, .{});
    exe.step.dependOn(&repo.step);
    //    exe.step.dependOn(&config_step.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        //        "main.c", "cmph.c", "hash.c", "chm.c", "bmz.c", "bmz8.c", "brz.c", "fch.c",
        //        "bdz.c", "bdz_ph.c", "chd_ph.c", "chd.c", "jenkins_hash.c", "graph.c", "vqueue.c",
        //        "buffer_manager.c", "fch_buckets.c", "miller_rabin.c", "compressed_seq.c",
        //        "compressed_rank.c", "buffer_entry.c", "select.c", "cmph_structs.c",
    };
    for (sources) |src| {
        files.append(b.pathJoin(&.{ repo_path, "src", src })) catch unreachable;
    }

    addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
        "-std=c11",
    });

    exe.addIncludePath(lazyPath(b, "inc/libc"));
    exe.addIncludePath(lazyPath(b, "inc/posix"));
    exe.addIncludePath(lazyPath(b, "inc/gnu"));
    exe.linkLibrary(libc_only_std_static);
    exe.linkLibrary(zig_start);
    exe.linkLibrary(zig_posix);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
    }

    const step = b.step("awk", "build awk");
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
