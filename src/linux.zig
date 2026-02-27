export fn alloca(size: usize) callconv(.c) [*]u8 {
    _ = size;
    @panic("alloca not implemented");
}
