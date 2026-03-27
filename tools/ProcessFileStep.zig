const std = @import("std");
const ProcessFileStep = @This();
const filecheck = @import("filecheck.zig");

step: std.Build.Step,
//builder: *std.Build,
in_filename: []const u8,
out_filename: []const u8,
subs: []const Sub,

pub const Sub = struct {
    current: []const u8,
    new: []const u8,
};

pub fn create(b: *std.Build, opt: struct {
    in_filename: []const u8,
    out_filename: []const u8,
    subs: []const Sub = &[_]Sub{},
}) *ProcessFileStep {
    const result = b.allocator.create(ProcessFileStep) catch unreachable;
    const name = std.fmt.allocPrint(b.allocator, "process file '{s}'", .{std.fs.path.basename(opt.in_filename)}) catch unreachable;
    result.* = ProcessFileStep{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = make,
        }),
        .in_filename = opt.in_filename,
        .out_filename = opt.out_filename,
        .subs = opt.subs,
    };
    return result;
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const self: *ProcessFileStep = @fieldParentPtr("step", step);
    const io = step.owner.graph.io;

    if (try filecheck.leftFileIsNewer(io, self.out_filename, self.in_filename)) {
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, self.in_filename, arena.allocator(), .unlimited) catch |err| {
        std.log.err("failed to read file '{s}' to process ({s})", .{ self.in_filename, @errorName(err) });
        std.process.exit(0xff);
    };
    const tmp_filename = try std.fmt.allocPrint(arena.allocator(), "{s}.processing", .{self.out_filename});
    {
        var out_file = try cwd.createFile(io, tmp_filename, .{});
        defer out_file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = out_file.writer(io, &buffer);
        try process(self.subs, &writer.interface, content);
        try writer.flush();
    }
    try cwd.rename(tmp_filename, cwd, self.out_filename, io);
}

fn process(subs: []const Sub, writer: anytype, content: []const u8) !void {
    var last_flush: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        const rest = content[i..];

        const match: ?Sub = blk: {
            for (subs) |sub| {
                if (std.mem.startsWith(u8, rest, sub.current)) {
                    break :blk sub;
                }
            }
            break :blk null;
        };

        if (match) |sub| {
            if (last_flush < i) try writer.writeAll(content[last_flush..i]);
            try writer.writeAll(sub.new);
            last_flush = i + sub.current.len;
            i = last_flush;
        } else {
            i += 1;
        }
    }

    if (last_flush < content.len) {
        try writer.writeAll(content[last_flush..]);
    }
}
