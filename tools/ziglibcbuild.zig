const std = @import("std");
const build = std.Build;
const CompileStep = build.Step.Compile;

pub const LinkKind = enum { static, shared };
pub const LibVariant = enum {
    only_std,
    only_posix,
    only_linux,
    only_gnu,
    full,
};
pub const Start = enum {
    ziglibc,
};
pub const ZigLibcOptions = struct {
    variant: LibVariant,
    link: LinkKind,
    start: Start,
    trace: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn relpath(builder: *build, src_path: []const u8) std.Build.LazyPath {
    return builder.path(src_path);
}

/// Provides a _start symbol that will call C main
pub fn addZigStart(
    builder: *build,
    target: std.Build.ResolvedTarget,
    optimize: anytype,
) *CompileStep {
    const lib = addStaticLibraryCompat(builder, .{
        .name = "start",
        .root_source_file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "start.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
    });
    return lib;
}

// Returns ziglibc as a CompileStep
// Caller will also need to add the include path to get the C headers
pub fn addLibc(builder: *std.Build, opt: ZigLibcOptions) *CompileStep {
    const name = switch (opt.variant) {
        .only_std => "c-only-std",
        .only_posix => "c-only-posix",
        .only_linux => "c-only-linux",
        .only_gnu => "c-only-gnu",
        //.full => "c",
        .full => "cguana", // use cguana to avoid passing in '-lc' to zig which will
        // cause it to add the system libc headers
    };
    const trace_options = builder.addOptions();
    trace_options.addOption(bool, "enabled", opt.trace);

    const modules_options = builder.addOptions();
    const index = relpath(builder, "src" ++ std.fs.path.sep_str ++ "lib.zig");
    const force_llvm_lld = opt.link == .shared and opt.target.result.os.tag == .linux;
    const lib = switch (opt.link) {
        .static => addStaticLibraryCompat(builder, .{
            .name = name,
            .root_source_file = index,
            .target = opt.target,
            .optimize = opt.optimize,
            .pic = true,
        }),
        .shared => addSharedLibraryCompat(builder, .{
            .name = name,
            .root_source_file = index,
            .target = opt.target,
            .optimize = opt.optimize,
            .pic = true,
            .use_llvm = if (force_llvm_lld) true else null,
            .use_lld = if (force_llvm_lld) true else null,
            .version = switch (opt.variant) {
                .full => .{ .major = 6, .minor = 0, .patch = 0 },
                else => null,
            },
        }),
    };
    lib.root_module.addOptions("modules", modules_options);
    lib.root_module.addOptions("trace_options", trace_options);
    const c_flags = [_][]const u8{
        "-std=c11",
    };
    const include_cstd = switch (opt.variant) {
        .only_std, .full => true,
        else => false,
    };
    modules_options.addOption(bool, "cstd", include_cstd);
    if (include_cstd) {
        lib.addCSourceFile(.{ .file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "printf.c"), .flags = &c_flags });
        lib.addCSourceFile(.{ .file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "scanf.c"), .flags = &c_flags });
        lib.addCSourceFile(.{ .file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "signal.c"), .flags = &c_flags });
    }
    const include_posix = switch (opt.variant) {
        .only_posix, .only_gnu, .full => true,
        else => false,
    };
    if (include_cstd or include_posix) {
        lib.addCSourceFile(.{ .file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "errno.c"), .flags = &c_flags });
    }
    modules_options.addOption(bool, "posix", include_posix);
    if (include_posix) {
        lib.addCSourceFile(.{ .file = relpath(builder, "src" ++ std.fs.path.sep_str ++ "posix.c"), .flags = &c_flags });
    }
    const include_linux = switch (opt.variant) {
        .only_linux, .full => true,
        else => false,
    };
    modules_options.addOption(bool, "linux", include_linux);
    if (include_cstd or include_posix) {
        lib.addIncludePath(relpath(builder, "inc" ++ std.fs.path.sep_str ++ "libc"));
        lib.addIncludePath(relpath(builder, "inc" ++ std.fs.path.sep_str ++ "posix"));
    }
    const include_gnu = switch (opt.variant) {
        .only_gnu, .full => true,
        else => false,
    };
    modules_options.addOption(bool, "gnu", include_gnu);
    if (include_gnu) {
        lib.addIncludePath(relpath(builder, "inc" ++ std.fs.path.sep_str ++ "gnu"));
    }
    return lib;
}

fn addStaticLibraryCompat(
    b: *std.Build,
    opt: struct {
        name: []const u8,
        root_source_file: ?std.Build.LazyPath = null,
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
        pic: ?bool = null,
    },
) *CompileStep {
    return b.addLibrary(.{
        .linkage = .static,
        .name = opt.name,
        .root_module = b.createModule(.{
            .root_source_file = opt.root_source_file,
            .target = opt.target orelse b.graph.host,
            .optimize = opt.optimize orelse .Debug,
            .pic = opt.pic,
        }),
    });
}

fn addSharedLibraryCompat(
    b: *std.Build,
    opt: struct {
        name: []const u8,
        root_source_file: ?std.Build.LazyPath = null,
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
        version: ?std.SemanticVersion = null,
        pic: ?bool = null,
        use_llvm: ?bool = null,
        use_lld: ?bool = null,
    },
) *CompileStep {
    return b.addLibrary(.{
        .linkage = .dynamic,
        .name = opt.name,
        .root_module = b.createModule(.{
            .root_source_file = opt.root_source_file,
            .target = opt.target orelse b.graph.host,
            .optimize = opt.optimize orelse .Debug,
            .pic = opt.pic,
        }),
        .use_llvm = opt.use_llvm,
        .use_lld = opt.use_lld,
        .version = opt.version,
    });
}
