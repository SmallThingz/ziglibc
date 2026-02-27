/// Run the given program in a clean directory
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn main() !u8 {
    const full_args = try std.process.argsAlloc(arena.allocator());
    if (full_args.len <= 1) {
        try std.fs.File.stderr().writeAll("Usage: testenv PROGRAM ARGS...\n");
        return 1;
    }
    const args = full_args[1..];
    var child_args = try arena.allocator().alloc([]const u8, args.len);
    @memcpy(child_args, args);
    child_args[0] = try std.fs.realpathAlloc(arena.allocator(), args[0]);

    // TODO: improve this
    const dirname = try std.fmt.allocPrint(arena.allocator(), "{s}.test.tmp", .{std.fs.path.basename(args[0])});
    try std.fs.cwd().deleteTree(dirname);
    try std.fs.cwd().makeDir(dirname);
    var child = std.process.Child.init(child_args, arena.allocator());
    child.cwd = dirname;
    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) return code;
        },
        else => |r| {
            std.log.err("child process failed with {}", .{r});
            return 0xff;
        },
    }
    try std.fs.cwd().deleteTree(dirname);
    return 0;
}
