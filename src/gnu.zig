const c = @cImport({
    @cInclude("argp.h");
    @cInclude("glob.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const std = @import("std");
const compat = @import("head_compat.zig");

fn errnoConst(comptime name: []const u8, fallback: c_int) c_int {
    if (@hasDecl(c, name)) return @field(c, name);
    return fallback;
}

export fn argp_usage(state: *const c.argp_state) callconv(.c) void {
    if (state.argc > 0 and state.argv != null and state.argv[0] != null) {
        _ = c.fprintf(c.stderr, "Usage: %s [OPTION...]\n", state.argv[0]);
    } else {
        _ = c.fprintf(c.stderr, "Usage: program [OPTION...]\n");
    }
}

export fn argp_parse(
    noalias argp: *c.argp,
    argc: c_int,
    noalias argv: [*:null]?[*:0]u8,
    flags: c_uint,
    noalias arg_index: *c_int,
    noalias input: *anyopaque,
) callconv(.c) c.error_t {
    const parser = argp.parser orelse {
        arg_index.* = 0;
        return 0;
    };

    var state: c.argp_state = .{
        .argc = argc,
        .argv = @ptrCast(argv),
        .next = 1,
        .flags = flags,
        .arg_num = 0,
        .input = input,
    };

    if (argc <= 1) {
        const rc = parser(c.ARGP_KEY_NO_ARGS, null, &state);
        if (rc != 0) {
            arg_index.* = state.next;
            return rc;
        }
    } else {
        state.arg_num = @as(c_uint, @intCast(argc - 1));
        const first_arg = argv[@as(usize, @intCast(state.next))];
        const rc = parser(c.ARGP_KEY_ARGS, @ptrCast(first_arg), &state);
        if (rc != 0) {
            arg_index.* = state.next;
            return rc;
        }
        state.next = argc;
    }

    const end_rc = parser(c.ARGP_KEY_END, null, &state);
    arg_index.* = state.next;
    return end_rc;
}

fn wildcardMatch(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    return switch (pattern[0]) {
        '*' => wildcardMatch(name, pattern[1..]) or (name.len != 0 and wildcardMatch(name[1..], pattern)),
        '?' => name.len != 0 and wildcardMatch(name[1..], pattern[1..]),
        else => name.len != 0 and name[0] == pattern[0] and wildcardMatch(name[1..], pattern[1..]),
    };
}

fn dupCString(slice: []const u8) ?[*:0]u8 {
    const buf = @as(?[*]u8, @ptrCast(c.malloc(slice.len + 1))) orelse return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @as([*:0]u8, @ptrCast(buf));
}

export fn glob(
    noalias pattern: [*:0]const u8,
    flags: c_int,
    errfunc: ?*const fn ([*:0]const u8, c_int) callconv(.c) c_int,
    noalias pglob: *c.glob_t,
) callconv(.c) c_int {
    _ = flags;
    _ = errfunc;
    globfree(pglob);

    const pattern_slice = std.mem.span(pattern);
    const slash_index = std.mem.lastIndexOfScalar(u8, pattern_slice, '/');
    const dir_path = if (slash_index) |idx| if (idx == 0) "/" else pattern_slice[0..idx] else ".";
    const base_pat = if (slash_index) |idx| pattern_slice[idx + 1 ..] else pattern_slice;

    var dir = (if (std.fs.path.isAbsolute(dir_path))
        compat.openDirAbsolute(dir_path, .{ .iterate = true })
    else
        compat.cwd().openDir(compat.io(), dir_path, .{ .iterate = true })) catch return 0;
    defer dir.close(compat.io());

    var iter = dir.iterate();
    var matches: std.ArrayListUnmanaged([*:0]u8) = .empty;
    defer matches.deinit(std.heap.page_allocator);

    while (true) {
        const entry = (iter.next(compat.io()) catch break) orelse break;
        if (!wildcardMatch(entry.name, base_pat)) continue;
        const full = if (slash_index) |_|
            std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue
        else
            std.heap.page_allocator.dupe(u8, entry.name) catch continue;
        defer std.heap.page_allocator.free(full);
        const owned = dupCString(full) orelse return errnoConst("ENOMEM", 1);
        matches.append(std.heap.page_allocator, owned) catch return errnoConst("ENOMEM", 1);
    }

    std.sort.heap([*:0]u8, matches.items, {}, struct {
        fn lessThan(_: void, a: [*:0]u8, b: [*:0]u8) bool {
            return std.mem.lessThan(u8, std.mem.span(a), std.mem.span(b));
        }
    }.lessThan);

    const total = pglob.gl_offs + matches.items.len + 1;
    const raw_pathv = c.calloc(total, @sizeOf([*c]u8)) orelse return errnoConst("ENOMEM", 1);
    const pathv: [*][*c]u8 = @ptrCast(@alignCast(raw_pathv));
    var i: usize = 0;
    while (i < pglob.gl_offs) : (i += 1) pathv[i] = null;
    for (matches.items, 0..) |match, idx| pathv[pglob.gl_offs + idx] = match;
    pathv[pglob.gl_offs + matches.items.len] = null;
    pglob.gl_pathc = matches.items.len;
    pglob.gl_pathv = pathv;
    return 0;
}

export fn globfree(pglob: *c.glob_t) callconv(.c) void {
    if (pglob.gl_pathv) |pathv| {
        var i: usize = pglob.gl_offs;
        while (i < pglob.gl_offs + pglob.gl_pathc) : (i += 1) {
            if (pathv[i]) |entry| c.free(entry);
        }
        c.free(@ptrCast(pathv));
    }
    pglob.gl_pathc = 0;
    pglob.gl_pathv = null;
}
