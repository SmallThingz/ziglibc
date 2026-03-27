const std = @import("std");

extern fn strlen(s: [*:0]const u8) callconv(.c) usize;
extern fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int;
extern fn strchr(s: [*:0]const u8, ch: c_int) callconv(.c) ?[*:0]const u8;
extern fn memchr(s: [*]const u8, ch: c_int, n: usize) callconv(.c) ?[*]const u8;
extern fn strrchr(s: [*:0]const u8, ch: c_int) callconv(.c) ?[*:0]const u8;
extern fn strcpy(dst: [*]u8, src: [*:0]const u8) callconv(.c) [*:0]u8;
extern fn strcat(dst: [*]u8, src: [*:0]const u8) callconv(.c) [*:0]u8;
extern fn clock_gettime(clk_id: std.c.clockid_t, tp: *std.c.timespec) callconv(.c) c_int;
extern fn qsort(
    base: ?*anyopaque,
    nmemb: usize,
    size: usize,
    compar: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int,
) callconv(.c) void;

const Bench = struct {
    name: []const u8,
    iterations: usize,
    run: *const fn () void,
};

var sink: usize = 0;
var long_a = [_]u8{0} ** 4097;
var long_b = [_]u8{0} ** 4097;
var diff_late = [_]u8{0} ** 4097;
var copy_src = [_]u8{0} ** 2049;
var append_src = [_]u8{0} ** 257;
var copy_dst = [_]u8{0} ** 4097;
var append_dst = [_]u8{0} ** 4097;
var mem_buf = [_]u8{0} ** 4096;
var sort_values = [_]u32{0} ** 1024;

fn emitResult(name: []const u8, total_ns: u64, iterations: usize) !void {
    const ns_per_iter = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("{s}: total_ns={d} ns_per_iter={d:.2}\n", .{ name, total_ns, ns_per_iter });
}

fn runBench(bench: Bench) !void {
    var start_ts: std.c.timespec = undefined;
    _ = clock_gettime(.MONOTONIC, &start_ts);
    var i: usize = 0;
    while (i < bench.iterations) : (i += 1) {
        bench.run();
    }
    var end_ts: std.c.timespec = undefined;
    _ = clock_gettime(.MONOTONIC, &end_ts);
    var sec_delta = end_ts.sec - start_ts.sec;
    var nsec_delta = end_ts.nsec - start_ts.nsec;
    if (nsec_delta < 0) {
        sec_delta -= 1;
        nsec_delta += std.time.ns_per_s;
    }
    const total_ns = @as(u64, @intCast(sec_delta)) * std.time.ns_per_s +
        @as(u64, @intCast(nsec_delta));
    try emitResult(bench.name, total_ns, bench.iterations);
}

fn fillPattern(buf: []u8) void {
    for (buf, 0..) |*byte, i| {
        byte.* = "abcdefghijklmnopqrstuvwxyz012345"[i % 32];
    }
}

fn initData() void {
    fillPattern(long_a[0 .. long_a.len - 1]);
    fillPattern(long_b[0 .. long_b.len - 1]);
    fillPattern(diff_late[0 .. diff_late.len - 1]);
    fillPattern(copy_src[0 .. copy_src.len - 1]);
    fillPattern(append_src[0 .. append_src.len - 1]);
    fillPattern(mem_buf[0..]);

    long_a[long_a.len - 1] = 0;
    long_b[long_b.len - 1] = 0;
    diff_late[diff_late.len - 1] = 0;
    copy_src[copy_src.len - 1] = 0;
    append_src[append_src.len - 1] = 0;

    long_a[3000] = '7';
    mem_buf[2048] = 'q';
    diff_late[diff_late.len - 2] = '!';
}

fn benchStrlen() void {
    sink +%= strlen(@ptrCast(&long_a));
}

fn benchStrcmpEqual() void {
    sink +%= @as(usize, @intCast(strcmp(@ptrCast(&long_a), @ptrCast(&long_b)) + 1));
}

fn benchStrcmpDiffLate() void {
    sink +%= @as(usize, @intCast(strcmp(@ptrCast(&long_a), @ptrCast(&diff_late)) + 256));
}

fn benchStrchrFound() void {
    const ptr = strchr(@ptrCast(&long_a), '7') orelse unreachable;
    sink +%= @intFromPtr(ptr);
}

fn benchMemchrFound() void {
    const ptr = memchr(&mem_buf, 'q', mem_buf.len) orelse unreachable;
    sink +%= @intFromPtr(ptr);
}

fn benchStrrchrFound() void {
    const ptr = strrchr(@ptrCast(&long_a), 'a') orelse unreachable;
    sink +%= @intFromPtr(ptr);
}

fn benchStrcpy() void {
    _ = strcpy(&copy_dst, @ptrCast(&copy_src));
    sink +%= copy_dst[copy_src.len - 2];
}

fn benchStrcat() void {
    @memcpy(append_dst[0..2048], copy_src[0..2048]);
    append_dst[2048] = 0;
    _ = strcat(&append_dst, @ptrCast(&append_src));
    sink +%= append_dst[2300];
}

fn u32Compare(lhs: ?*const anyopaque, rhs: ?*const anyopaque) callconv(.c) c_int {
    const a: *const u32 = @ptrCast(@alignCast(lhs.?));
    const b: *const u32 = @ptrCast(@alignCast(rhs.?));
    return if (a.* < b.*) -1 else if (a.* > b.*) 1 else 0;
}

fn benchQsort() void {
    var prng = std.Random.DefaultPrng.init(0x12345678);
    for (&sort_values) |*value| {
        value.* = prng.random().int(u32);
    }
    qsort(&sort_values, sort_values.len, @sizeOf(u32), u32Compare);
    sink +%= sort_values[0];
}

pub fn main() !void {
    initData();
    const benches = [_]Bench{
        .{ .name = "strlen-long", .iterations = 2_000_000, .run = benchStrlen },
        .{ .name = "strcmp-equal", .iterations = 1_000_000, .run = benchStrcmpEqual },
        .{ .name = "strcmp-diff-late", .iterations = 1_000_000, .run = benchStrcmpDiffLate },
        .{ .name = "strchr-found", .iterations = 2_000_000, .run = benchStrchrFound },
        .{ .name = "memchr-found", .iterations = 2_000_000, .run = benchMemchrFound },
        .{ .name = "strrchr-found", .iterations = 1_000_000, .run = benchStrrchrFound },
        .{ .name = "strcpy-2k", .iterations = 500_000, .run = benchStrcpy },
        .{ .name = "strcat-2k+256", .iterations = 300_000, .run = benchStrcat },
        .{ .name = "qsort-u32-1024", .iterations = 10_000, .run = benchQsort },
    };

    for (benches) |bench| try runBench(bench);
    std.debug.print("sink={d}\n", .{sink});
}
