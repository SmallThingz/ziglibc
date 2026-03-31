const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return 1;
    if (!std.mem.eql(u8, args[1], "alpha")) return 1;
    if (!std.mem.eql(u8, args[2], "beta")) return 1;

    var env = try init.minimal.environ.createMap(init.arena.allocator());
    defer env.deinit();

    if (env.get("ZIGLIBC_PROCESS_CHECK") == null) return 1;

    try std.Io.File.stdout().writeStreamingAll(init.io, "Success!\n");
    return 0;
}
