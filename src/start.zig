const builtin = @import("builtin");
const std = @import("std");

const c = struct {
    extern fn main(argc: c_int, argv: [*:null]?[*:0]u8) callconv(.c) c_int;
};

pub fn main() u8 {
    var argc: c_int = undefined;
    const args: [*:null]?[*:0]u8 = blk: {
        if (builtin.os.tag == .windows) {
            const args = windowsArgsAlloc();
            argc = @intCast(args.len);
            break :blk args.ptr;
        }
        argc = @as(c_int, @intCast(std.os.argv.len));
        break :blk @as([*:null]?[*:0]u8, @ptrCast(std.os.argv.ptr));
    };

    var result = c.main(argc, args);
    if (result != 0) {
        while ((result & 0xff == 0)) result = result >> 8;
    }
    return @as(u8, @intCast(result & 0xff));
}

// TODO: I'm pretty sure this could be more memory efficient
fn windowsArgsAlloc() [:null]?[*:0]u8 {
    var argv_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp_arena.deinit();

    var argv = std.ArrayListUnmanaged(?[*:0]u8){};
    var it = std.process.argsWithAllocator(tmp_arena.allocator()) catch std.posix.abort();
    defer it.deinit();
    while (it.next()) |tmp_arg| {
        const arg = argv_arena.allocator().dupeZ(u8, tmp_arg) catch std.posix.abort();
        argv.append(argv_arena.allocator(), arg) catch std.posix.abort();
    }
    return argv.toOwnedSliceSentinel(argv_arena.allocator(), null) catch std.posix.abort();
}
