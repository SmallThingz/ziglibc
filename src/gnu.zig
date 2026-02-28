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
    _ = argp;
    _ = argc;
    _ = argv;
    _ = flags;
    _ = input;
    arg_index.* = 0;
    return c.ARGP_ERR_UNKNOWN;
}
