const builtin = @import("builtin");
const std = @import("std");
const compat = @import("head_compat.zig");

const c = struct {
    extern fn main(argc: c_int, argv: [*:null]?[*:0]u8) callconv(.c) c_int;
};

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = argsAlloc(init);
    const argc: c_int = @intCast(args.len);
    var result = c.main(argc, args);
    if (result != 0) {
        while ((result & 0xff == 0)) result = result >> 8;
    }
    return @as(u8, @intCast(result & 0xff));
}

fn argsAlloc(init: std.process.Init.Minimal) [:null]?[*:0]u8 {
    var argv_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var argv: std.ArrayListUnmanaged(?[*:0]u8) = .empty;
    const args = init.args.vector;
    for (args) |tmp_arg| {
        var len: usize = 0;
        while ((@as(*align(1) const volatile u8, @ptrCast(tmp_arg + len))).* != 0) : (len += 1) {}
        const arg = argv_arena.allocator().dupeZ(u8, tmp_arg[0..len]) catch compat.abort();
        argv.append(argv_arena.allocator(), arg) catch compat.abort();
    }
    return argv.toOwnedSliceSentinel(argv_arena.allocator(), null) catch compat.abort();
}
