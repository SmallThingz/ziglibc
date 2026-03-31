const std = @import("std");
const trace_options = @import("trace_options");

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (trace_options.enabled) {
        std.log.scoped(.trace).info(fmt, args);
    }
}
