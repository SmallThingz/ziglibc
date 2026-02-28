const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");
const libcbuild = @import("ziglibcbuild.zig");
const luabuild = @import("luabuild.zig");
const awkbuild = @import("awkbuild.zig");
const gnumakebuild = @import("gnumakebuild.zig");

pub fn build(b: *std.Build) void {
    const trace_enabled = b.option(bool, "trace", "enable libc tracing") orelse false;

    {
        const exe = addExecutableCompat(b, .{
            .name = "genheaders",
            .root_source_file = lazyPath(b, "src" ++ std.fs.path.sep_str ++ "genheaders.zig"),
        });
        const run = b.addRunArtifact(exe);
        run.addArg(b.pathFromRoot("capi.txt"));
        b.step("genheaders", "Generate C Headers").dependOn(&run.step);
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_start = libcbuild.addZigStart(b, target, optimize);
    b.step("start", "").dependOn(&installArtifact(b, zig_start).step);

    const libc_full_static = libcbuild.addLibc(b, .{
        .variant = .full,
        .link = .static,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_full_static);
    const libc_full_shared = libcbuild.addLibc(b, .{
        .variant = .full,
        .link = .shared,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.step("libc-full-shared", "").dependOn(&installArtifact(b, libc_full_shared).step);
    // TODO: create a specs file?
    //       you can add -specs=file to the gcc command line to override values in the spec

    const libc_only_std_static = libcbuild.addLibc(b, .{
        .variant = .only_std,
        .link = .static,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_only_std_static);
    const libc_only_std_shared = libcbuild.addLibc(b, .{
        .variant = .only_std,
        .link = .shared,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_only_std_shared);

    const libc_only_posix = libcbuild.addLibc(b, .{
        .variant = .only_posix,
        .link = .static,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_only_posix);

    const libc_only_linux = libcbuild.addLibc(b, .{
        .variant = .only_linux,
        .link = .static,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_only_linux);

    const libc_only_gnu = libcbuild.addLibc(b, .{
        .variant = .only_gnu,
        .link = .static,
        .start = .ziglibc,
        .trace = trace_enabled,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(libc_only_gnu);

    const test_step = b.step("test", "Run unit tests");

    const test_env_exe = addExecutableCompat(b, .{
        .name = "testenv",
        .root_source_file = lazyPath(b, "test" ++ std.fs.path.sep_str ++ "testenv.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const exe = addTest("hello", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Hello\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("strings", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("signal_extensive", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("gnu_extensive", b, target, optimize, libc_only_std_static, zig_start);
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "gnu"));
        exe.linkLibrary(libc_only_gnu);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("fs", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(test_env_exe);
        run_step.addArtifactArg(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("format", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(test_env_exe);
        run_step.addArtifactArg(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("types", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addArg(b.fmt("{}", .{@divExact(target.result.ptrBitWidth(), 8)}));
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("scanf", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("strto", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("stdlib_extensive", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("stdio_extensive", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(test_env_exe);
        run_step.addArtifactArg(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("panic_replacements", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(test_env_exe);
        run_step.addArtifactArg(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("posix_extensive", b, target, optimize, libc_only_std_static, zig_start);
        addPosix(exe, libc_only_posix);
        const run_step = b.addRunArtifact(test_env_exe);
        run_step.addArtifactArg(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    {
        const exe = addTest("getopt", b, target, optimize, libc_only_std_static, zig_start);
        addPosix(exe, libc_only_posix);
        {
            const run = b.addRunArtifact(exe);
            run.addCheck(.{ .expect_stdout_exact = "aflag=0, c_arg='(null)'\n" });
            test_step.dependOn(&run.step);
        }
        {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{"-a"});
            run.addCheck(.{ .expect_stdout_exact = "aflag=1, c_arg='(null)'\n" });
            test_step.dependOn(&run.step);
        }
        {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-c", "hello" });
            run.addCheck(.{ .expect_stdout_exact = "aflag=0, c_arg='hello'\n" });
            test_step.dependOn(&run.step);
        }
        {
            const run = b.addRunArtifact(exe);
            run.addArgs(&.{ "-ac", "hello" });
            run.addCheck(.{ .expect_stdout_exact = "aflag=1, c_arg='hello'\n" });
            test_step.dependOn(&run.step);
        }
        {
            const run = b.addRunArtifact(exe);
            run.addArg("-achello");
            run.addCheck(.{ .expect_stdout_exact = "aflag=1, c_arg='hello'\n" });
            test_step.dependOn(&run.step);
        }
    }

    if (supportsSetjmp(target.result)) {
        const exe = addTest("jmp", b, target, optimize, libc_only_std_static, zig_start);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }
    if (target.result.os.tag == .linux) {
        const exe = addTest("alloca_extensive", b, target, optimize, libc_only_std_static, zig_start);
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "linux"));
        exe.linkLibrary(libc_only_linux);
        const run_step = b.addRunArtifact(exe);
        run_step.addCheck(.{ .expect_stdout_exact = "Success!\n" });
        test_step.dependOn(&run_step.step);
    }

    const libc_conformance_step = addLibcTest(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix);
    const regex_conformance_step = addTinyRegexCTests(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix);
    const glibc_check_step = addGlibcCheck(
        b,
        target,
        optimize,
    );
    const posix_test_suite_step = addPosixTestSuite(
        b,
        target,
        optimize,
        libc_only_std_static,
        zig_start,
        libc_only_posix,
    );
    const austin_group_tests_step = addAustinGroupTests(
        b,
        target,
        optimize,
        libc_only_std_static,
        zig_start,
        libc_only_posix,
    );
    const conformance_step = b.step("conformance", "Run libc conformance suites");
    conformance_step.dependOn(libc_conformance_step);
    conformance_step.dependOn(regex_conformance_step);
    // glibc-check is only relevant for Linux targets using glibc.
    if (std.Target.isGnuLibC(&target.result)) {
        conformance_step.dependOn(glibc_check_step);
    }
    // POSIX and Austin Group suites apply to POSIX targets.
    if (supportsPosixConformance(target.result.os.tag)) {
        conformance_step.dependOn(posix_test_suite_step);
        conformance_step.dependOn(austin_group_tests_step);
    }
    _ = addLua(b, target, optimize, libc_only_std_static, libc_only_posix, zig_start);
    _ = addCmph(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix);
    _ = addYacc(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix);
    _ = addYabfc(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix, libc_only_gnu);
    _ = addSecretGame(b, target, optimize, libc_only_std_static, zig_start, libc_only_posix, libc_only_gnu);
    _ = awkbuild.addAwk(b, target, optimize, libc_only_std_static, libc_only_posix, zig_start);
    _ = gnumakebuild.addGnuMake(b, target, optimize, libc_only_std_static, libc_only_posix, zig_start);

    _ = @import("busybox/build.zig").add(b, target, optimize, libc_only_std_static, libc_only_posix);
    _ = @import("ncurses/build.zig").add(b, target, optimize, libc_only_std_static, libc_only_posix);
}

// re-implements Build.installArtifact but also returns it
fn installArtifact(b: *std.Build, artifact: anytype) *std.Build.Step.InstallArtifact {
    const install = b.addInstallArtifact(artifact, .{});
    b.getInstallStep().dependOn(&install.step);
    return install;
}

fn supportsPosixConformance(os_tag: std.Target.Os.Tag) bool {
    return switch (std.Target.DynamicLinker.kind(os_tag)) {
        .none => false,
        .arch_os, .arch_os_abi => true,
    };
}

fn supportsSetjmp(target: std.Target) bool {
    return switch (target.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
}

fn addPosix(artifact: *std.Build.Step.Compile, zig_posix: *std.Build.Step.Compile) void {
    artifact.linkLibrary(zig_posix);
    artifact.addIncludePath(lazyPath(artifact.step.owner, "inc" ++ std.fs.path.sep_str ++ "posix"));
}

fn addTest(
    comptime name: []const u8,
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const exe = addExecutableCompat(b, .{
        .name = name,
        .root_source_file = lazyPath(b, "test" ++ std.fs.path.sep_str ++ name ++ ".c"),
        .target = target,
        .optimize = optimize,
    });
    addCSourceFilesCompat(exe, &.{"test" ++ std.fs.path.sep_str ++ "expect.c"}, &.{});
    exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
    exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "posix"));
    exe.linkLibrary(libc_only_std_static);
    exe.linkLibrary(zig_start);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
    }
    return exe;
}

fn addGlibcCheck(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
) *std.Build.Step {
    const glibc_check_step = b.step("glibc-check", "Run glibc check conformance tests");
    if (!std.Target.isGnuLibC(&target.result)) {
        return glibc_check_step;
    }

    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/cloudius-systems/glibc-testsuite",
        .sha = "c1278866ed57e51576a78b71c6326115004a9676",
        .branch = null,
        .fetch_enabled = true,
    });
    const repo_path = repo.path;

    inline for (.{ "io/tst-getcwd.c", "libio/test-fmemopen.c", "malloc/tst-malloc.c", "rt/tst-clock.c" }) |src| {
        const name = b.fmt("glibc-check-{s}", .{std.mem.replaceOwned(u8, b.allocator, src, "/", "-") catch unreachable});
        const exe = addExecutableCompat(b, .{
            .name = name,
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        });
        addCSourceFilesCompat(exe, &.{b.pathJoin(&.{ repo_path, src })}, &.{"-D_GNU_SOURCE"});
        exe.step.dependOn(&repo.step);
        exe.addIncludePath(lazyPath(b, repo_path));
        exe.linkLibC();
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ntdll");
            exe.linkSystemLibrary("kernel32");
        }
        glibc_check_step.dependOn(&b.addRunArtifact(exe).step);
    }

    return glibc_check_step;
}

fn addPosixTestSuite(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    libc_only_posix: *std.Build.Step.Compile,
) *std.Build.Step {
    const posix_test_suite_step = b.step("posix-test-suite", "Run POSIX Test Suite conformance tests");
    if (!supportsPosixConformance(target.result.os.tag)) {
        return posix_test_suite_step;
    }

    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/nloopa/open_posix_testsuite",
        .sha = "b803d6e01aa516b234e784bc46aa3446881fac53",
        .branch = null,
        .fetch_enabled = true,
    });
    const repo_path = repo.path;
    const include_path = b.pathJoin(&.{ repo_path, "include" });

    inline for (.{"conformance/interfaces/clock_gettime/1-1.c"}) |src| {
        const name = b.fmt("posix-test-suite-{s}", .{std.mem.replaceOwned(u8, b.allocator, src, "/", "-") catch unreachable});
        const exe = addExecutableCompat(b, .{
            .name = name,
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        });
        addCSourceFilesCompat(exe, &.{b.pathJoin(&.{ repo_path, src })}, &.{
            "-std=c11",
            "-D_POSIX_C_SOURCE=200112L",
            "-D_XOPEN_SOURCE=600",
        });
        exe.step.dependOn(&repo.step);
        exe.addIncludePath(lazyPath(b, include_path));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "posix"));
        exe.linkLibrary(libc_only_std_static);
        exe.linkLibrary(zig_start);
        exe.linkLibrary(libc_only_posix);
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ntdll");
            exe.linkSystemLibrary("kernel32");
        }
        posix_test_suite_step.dependOn(&b.addRunArtifact(exe).step);
    }

    return posix_test_suite_step;
}

fn addAustinGroupTests(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    libc_only_posix: *std.Build.Step.Compile,
) *std.Build.Step {
    const austin_group_tests_step = b.step("austin-group-tests", "Run Austin Group POSIX conformance tests");
    if (!supportsPosixConformance(target.result.os.tag)) {
        return austin_group_tests_step;
    }

    const repo = GitRepoStep.create(b, .{
        .url = "git://nsz.repo.hu:49100/repo/libc-test",
        .sha = "b7ec467969a53756258778fa7d9b045f912d1c93",
        .branch = null,
        .fetch_enabled = true,
    });
    const repo_path = repo.path;
    const common_inc_path = b.pathJoin(&.{ repo_path, "src", "common" });
    const common_src = &[_][]const u8{
        b.pathJoin(&.{ repo_path, "src", "common", "print.c" }),
    };

    inline for (.{"functional/strftime.c"}) |src| {
        const name = b.fmt("austin-group-tests-{s}", .{std.mem.replaceOwned(u8, b.allocator, src, "/", "-") catch unreachable});
        const exe = addExecutableCompat(b, .{
            .name = name,
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        });
        addCSourceFilesCompat(exe, &.{b.pathJoin(&.{ repo_path, "src", src })}, &.{
            "-Dsetenv(a,b,c)=0",
        });
        addCSourceFilesCompat(exe, common_src, &.{});
        exe.step.dependOn(&repo.step);
        exe.addIncludePath(lazyPath(b, common_inc_path));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "posix"));
        exe.linkLibrary(libc_only_std_static);
        exe.linkLibrary(zig_start);
        exe.linkLibrary(libc_only_posix);
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ntdll");
            exe.linkSystemLibrary("kernel32");
        }
        austin_group_tests_step.dependOn(&b.addRunArtifact(exe).step);
    }

    return austin_group_tests_step;
}

fn addLibcTest(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    libc_only_posix: *std.Build.Step.Compile,
) *std.Build.Step {
    const libc_test_repo = GitRepoStep.create(b, .{
        .url = "git://nsz.repo.hu:49100/repo/libc-test",
        .sha = "b7ec467969a53756258778fa7d9b045f912d1c93",
        .branch = null,
        .fetch_enabled = true,
    });
    const libc_test_path = libc_test_repo.path;
    const libc_test_step = b.step("libc-test", "run tests from the libc-test project");

    // inttypes
    inline for (.{ "assert", "ctype", "errno", "main", "stdbool", "stddef", "string" }) |name| {
        const lib = addObjectCompat(b, .{
            .name = "libc-test-api-" ++ name,
            .root_source_file = lazyPath(b, b.pathJoin(&.{ libc_test_path, "src", "api", name ++ ".c" })),
            .target = target,
            .optimize = optimize,
        });
        lib.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
        lib.step.dependOn(&libc_test_repo.step);
        libc_test_step.dependOn(&lib.step);
    }
    const libc_inc_path = b.pathJoin(&.{ libc_test_path, "src", "common" });
    const common_src = &[_][]const u8{
        b.pathJoin(&.{ libc_test_path, "src", "common", "print.c" }),
    };

    // strtol, it seems there might be some disagreement between libc-test/glibc
    // about how strtoul interprets negative numbers, so leaving out strtol for now
    inline for (.{ "argv", "basename", "clock_gettime", "string" }) |name| {
        const exe = addExecutableCompat(b, .{
            .name = "libc-test-functional-" ++ name,
            .root_source_file = lazyPath(b, b.pathJoin(&.{ libc_test_path, "src", "functional", name ++ ".c" })),
            .target = target,
            .optimize = optimize,
        });
        addCSourceFilesCompat(exe, common_src, &.{});
        exe.step.dependOn(&libc_test_repo.step);
        exe.addIncludePath(lazyPath(b, libc_inc_path));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
        exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "posix"));
        exe.linkLibrary(libc_only_std_static);
        exe.linkLibrary(zig_start);
        exe.linkLibrary(libc_only_posix);
        // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ntdll");
            exe.linkSystemLibrary("kernel32");
        }
        libc_test_step.dependOn(&b.addRunArtifact(exe).step);
    }
    return libc_test_step;
}

fn addTinyRegexCTests(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
) *std.Build.Step {
    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/tiny-regex-c",
        .sha = "95ef2ad35d36783d789b0ade3178b30a942f085c",
        .branch = "nocompile",
        .fetch_enabled = true,
    });

    const re_step = b.step("re-tests", "run the tiny-regex-c tests");
    inline for (&[_][]const u8{ "test1", "test3" }) |test_name| {
        const exe = addExecutableCompat(b, .{
            .name = "re" ++ test_name,
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        });
        //b.installArtifact(exe);
        exe.step.dependOn(&repo.step);
        const repo_path = repo.getPath(&exe.step);
        var files = std.array_list.Managed([]const u8).init(b.allocator);
        const sources = [_][]const u8{
            "re.c", "tests" ++ std.fs.path.sep_str ++ test_name ++ ".c",
        };
        for (sources) |src| {
            files.append(b.pathJoin(&.{ repo_path, src })) catch unreachable;
        }

        addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
            "-std=c99",
        });
        exe.addIncludePath(lazyPath(b, repo_path));

        exe.addIncludePath(lazyPath(b, "inc/libc"));
        exe.addIncludePath(lazyPath(b, "inc/posix"));
        exe.linkLibrary(libc_only_std_static);
        exe.linkLibrary(zig_start);
        exe.linkLibrary(zig_posix);
        // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ntdll");
            exe.linkSystemLibrary("kernel32");
        }

        //const step = b.step("re", "build the re (tiny-regex-c) tool");
        //step.dependOn(&exe.install_step.?.step);
        const run = b.addRunArtifact(exe);
        re_step.dependOn(&run.step);
    }
    return re_step;
}

fn addLua(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    libc_only_posix: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const lua_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/lua/lua",
        .sha = "5d708c3f9cae12820e415d4f89c9eacbe2ab964b",
        .branch = "v5.4.4",
        .fetch_enabled = true,
    });
    const lua_exe = addExecutableCompat(b, .{
        .name = "lua",
        .target = target,
        .optimize = optimize,
    });
    lua_exe.step.dependOn(&lua_repo.step);
    const install = b.addInstallArtifact(lua_exe, .{});
    // doesn't compile for windows for some reason
    if (target.result.os.tag != .windows) {
        b.getInstallStep().dependOn(&install.step);
    }
    const lua_repo_path = lua_repo.getPath(&lua_exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    files.append(b.pathJoin(&.{ lua_repo_path, "lua.c" })) catch unreachable;
    inline for (luabuild.core_objects) |obj| {
        files.append(b.pathJoin(&.{ lua_repo_path, obj ++ ".c" })) catch unreachable;
    }
    inline for (luabuild.aux_objects) |obj| {
        files.append(b.pathJoin(&.{ lua_repo_path, obj ++ ".c" })) catch unreachable;
    }
    inline for (luabuild.lib_objects) |obj| {
        files.append(b.pathJoin(&.{ lua_repo_path, obj ++ ".c" })) catch unreachable;
    }

    addCSourceFilesCompat(lua_exe, files.toOwnedSlice() catch unreachable, &.{
        "-nostdinc",
        "-nostdlib",
        "-std=c99",
    });

    lua_exe.addIncludePath(lazyPath(b, "inc" ++ std.fs.path.sep_str ++ "libc"));
    lua_exe.linkLibrary(libc_only_std_static);
    lua_exe.linkLibrary(libc_only_posix);
    lua_exe.linkLibrary(zig_start);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        lua_exe.addIncludePath(lazyPath(b, "inc/win32"));
        lua_exe.linkSystemLibrary("ntdll");
        lua_exe.linkSystemLibrary("kernel32");
    }

    const step = b.step("lua", "build/install the LUA interpreter");
    step.dependOn(&install.step);

    const test_step = b.step("lua-test", "Run the lua tests");

    for ([_][]const u8{ "bwcoercion.lua", "tracegc.lua" }) |test_file| {
        var run_test = b.addRunArtifact(lua_exe);
        run_test.addArg(b.pathJoin(&.{ lua_repo_path, "testes", test_file }));
        test_step.dependOn(&run_test.step);
    }

    return lua_exe;
}

fn addCmph(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        //.url = "https://git.code.sf.net/p/cmph/git",
        .url = "https://github.com/bonitao/cmph",
        .sha = "abd5e1e17e4d51b3e24459ab9089dc0522846d0d",
        .branch = null,
        .fetch_enabled = true,
    });

    const config_step = b.addWriteFile(
        b.pathJoin(&.{ repo.path, "src", "config.h" }),
        "#define VERSION \"1.0\"",
    );
    config_step.step.dependOn(&repo.step);

    const exe = addExecutableCompat(b, .{
        .name = "cmph",
        .target = target,
        .optimize = optimize,
    });
    const install = installArtifact(b, exe);
    exe.step.dependOn(&repo.step);
    exe.step.dependOn(&config_step.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        "main.c",        "cmph.c",         "hash.c",           "chm.c",             "bmz.c",          "bmz8.c",   "brz.c",          "fch.c",
        "bdz.c",         "bdz_ph.c",       "chd_ph.c",         "chd.c",             "jenkins_hash.c", "graph.c",  "vqueue.c",       "buffer_manager.c",
        "fch_buckets.c", "miller_rabin.c", "compressed_seq.c", "compressed_rank.c", "buffer_entry.c", "select.c", "cmph_structs.c",
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

    const step = b.step("cmph", "build the cmph tool");
    step.dependOn(&install.step);

    return exe;
}

fn addYacc(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/ibara/yacc",
        .sha = "1a4138ce2385ec676c6d374245fda5a9cd2fbee2",
        .branch = null,
        .fetch_enabled = true,
    });

    const config_step = b.addWriteFile(b.pathJoin(&.{ repo.path, "config.h" }),
        \\// for simplicity just don't supported __unused
        \\#define __unused
        \\// for simplicity we're just not supporting noreturn
        \\#define __dead
        \\//#define HAVE_PROGNAME
        \\//#define HAVE_ASPRINTF
        \\//#define HAVE_PLEDGE
        \\//#define HAVE_REALLOCARRAY
        \\#define HAVE_STRLCPY
        \\
    );
    config_step.step.dependOn(&repo.step);
    const gen_progname_step = b.addWriteFile(b.pathJoin(&.{ repo.path, "progname.c" }),
        \\// workaround __progname not defined, https://github.com/ibara/yacc/pull/1
        \\char *__progname;
        \\
    );
    gen_progname_step.step.dependOn(&repo.step);

    const exe = addExecutableCompat(b, .{
        .name = "yacc",
        .target = target,
        .optimize = optimize,
    });
    const install = installArtifact(b, exe);
    exe.step.dependOn(&repo.step);
    exe.step.dependOn(&config_step.step);
    exe.step.dependOn(&gen_progname_step.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        "closure.c",  "error.c",  "lalr.c",    "lr0.c",      "main.c",     "mkpar.c",    "output.c", "reader.c",
        "skeleton.c", "symtab.c", "verbose.c", "warshall.c", "portable.c", "progname.c",
    };
    for (sources) |src| {
        files.append(b.pathJoin(&.{ repo_path, src })) catch unreachable;
    }

    addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
        "-std=c90",
    });

    exe.addIncludePath(lazyPath(b, "inc/libc"));
    exe.addIncludePath(lazyPath(b, "inc/posix"));
    exe.linkLibrary(libc_only_std_static);
    exe.linkLibrary(zig_start);
    exe.linkLibrary(zig_posix);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
    }

    const step = b.step("yacc", "build the yacc tool");
    step.dependOn(&install.step);

    return exe;
}

fn addYabfc(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
    zig_gnu: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/julianneswinoga/yabfc",
        .sha = "a789be25a0918d330b7a4de12db0d33e0785f244",
        .branch = null,
        .fetch_enabled = true,
    });

    const exe = addExecutableCompat(b, .{
        .name = "yabfc",
        .target = target,
        .optimize = optimize,
    });
    const install = installArtifact(b, exe);
    exe.step.dependOn(&repo.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        "assembly.c", "elfHelper.c", "helpers.c", "optimize.c", "yabfc.c",
    };
    for (sources) |src| {
        files.append(b.pathJoin(&.{ repo_path, src })) catch unreachable;
    }
    addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
        "-std=c99",
    });

    exe.addIncludePath(lazyPath(b, "inc/libc"));
    exe.addIncludePath(lazyPath(b, "inc/posix"));
    exe.addIncludePath(lazyPath(b, "inc/linux"));
    exe.addIncludePath(lazyPath(b, "inc/gnu"));
    exe.linkLibrary(libc_only_std_static);
    exe.linkLibrary(zig_start);
    exe.linkLibrary(zig_posix);
    exe.linkLibrary(zig_gnu);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
    }

    const step = b.step("yabfc", "build/install the yabfc tool (Yet Another BrainFuck Compiler)");
    step.dependOn(&install.step);

    return exe;
}

fn addSecretGame(
    b: *std.Build,
    target: anytype,
    optimize: anytype,
    libc_only_std_static: *std.Build.Step.Compile,
    zig_start: *std.Build.Step.Compile,
    zig_posix: *std.Build.Step.Compile,
    zig_gnu: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const repo = GitRepoStep.create(b, .{
        .url = "https://github.com/ethinethin/Secret",
        .sha = "8ec8442f84f8bed2cb3985455e7af4d1ce605401",
        .branch = null,
        .fetch_enabled = true,
    });

    const exe = addExecutableCompat(b, .{
        .name = "secret",
        .target = target,
        .optimize = optimize,
    });
    const install = b.addInstallArtifact(exe, .{});
    exe.step.dependOn(&repo.step);
    const repo_path = repo.getPath(&exe.step);
    var files = std.array_list.Managed([]const u8).init(b.allocator);
    const sources = [_][]const u8{
        "main.c", "inter.c", "input.c", "items.c", "rooms.c", "linenoise/linenoise.c",
    };
    for (sources) |src| {
        files.append(b.pathJoin(&.{ repo_path, src })) catch unreachable;
    }
    addCSourceFilesCompat(exe, files.toOwnedSlice() catch unreachable, &.{
        "-std=c90",
    });

    exe.addIncludePath(lazyPath(b, "inc/libc"));
    exe.addIncludePath(lazyPath(b, "inc/posix"));
    exe.addIncludePath(lazyPath(b, "inc/linux"));
    exe.addIncludePath(lazyPath(b, "inc/gnu"));
    exe.linkLibrary(libc_only_std_static);
    exe.linkLibrary(zig_start);
    exe.linkLibrary(zig_posix);
    exe.linkLibrary(zig_gnu);
    // TODO: should libc_only_std_static and zig_start be able to add library dependencies?
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ntdll");
        exe.linkSystemLibrary("kernel32");
    }

    const step = b.step("secret", "build/install the secret game");
    step.dependOn(&install.step);

    return exe;
}

fn addExecutableCompat(
    b: *std.Build,
    opt: struct {
        name: []const u8,
        root_source_file: ?std.Build.LazyPath = null,
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
    },
) *std.Build.Step.Compile {
    const has_zig_root = if (opt.root_source_file) |root|
        std.mem.endsWith(u8, root.getDisplayName(), ".zig")
    else
        false;
    const exe = b.addExecutable(.{
        .name = opt.name,
        .root_module = b.createModule(.{
            .root_source_file = if (has_zig_root) opt.root_source_file else null,
            .target = opt.target orelse b.graph.host,
            .optimize = opt.optimize orelse .Debug,
        }),
    });
    if (opt.root_source_file) |root| {
        if (!has_zig_root) {
            exe.addCSourceFile(.{
                .file = root,
                .flags = &.{},
            });
        }
    }
    return exe;
}

fn addObjectCompat(
    b: *std.Build,
    opt: struct {
        name: []const u8,
        root_source_file: ?std.Build.LazyPath = null,
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
    },
) *std.Build.Step.Compile {
    const has_zig_root = if (opt.root_source_file) |root|
        std.mem.endsWith(u8, root.getDisplayName(), ".zig")
    else
        false;
    const obj = b.addObject(.{
        .name = opt.name,
        .root_module = b.createModule(.{
            .root_source_file = if (has_zig_root) opt.root_source_file else null,
            .target = opt.target orelse b.graph.host,
            .optimize = opt.optimize orelse .Debug,
        }),
    });
    if (opt.root_source_file) |root| {
        if (!has_zig_root) {
            obj.addCSourceFile(.{
                .file = root,
                .flags = &.{},
            });
        }
    }
    return obj;
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
