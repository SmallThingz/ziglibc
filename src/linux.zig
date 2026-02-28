const std = @import("std");

export fn alloca(size: usize) callconv(.c) [*]u8 {
    const actual_size: usize = if (size == 0) 1 else size;
    const buf = std.heap.page_allocator.alignedAlloc(u8, .of(usize), actual_size) catch {
        std.posix.abort();
    };
    return buf.ptr;
}
