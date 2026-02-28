const c = @cImport({
    @cInclude("argp.h");
});

export fn argp_usage(state: *const c.argp_state) callconv(.c) void {
    _ = state;
    // No-op fallback for now.
}

export fn argp_parse(
    argp: *c.argp,
    argc: c_int,
    argv: [*:null]?[*:0]u8,
    flags: c_uint,
    arg_index: *c_int,
    input: *anyopaque,
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
