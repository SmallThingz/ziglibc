const std = @import("std");

pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn abort() noreturn {
    std.process.abort();
}

pub fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    std.Io.sleep(io(), .fromNanoseconds(@intCast(ns)), .awake) catch {};
}

pub fn nanoTimestamp() i128 {
    return @intCast(std.Io.Timestamp.now(io(), .real).toNanoseconds());
}

pub fn timestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toSeconds();
}

pub fn openFileAbsolute(path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    return std.Io.Dir.openFileAbsolute(io(), path, flags);
}

pub fn openDirAbsolute(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io(), path, options);
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn closeFile(file: std.Io.File) void {
    file.close(io());
}

pub fn readFileShort(file: std.Io.File, buffer: []u8) !usize {
    var reader_buf: [1024]u8 = undefined;
    var reader = file.reader(io(), &reader_buf);
    return reader.interface.readSliceShort(buffer);
}

pub fn populateLinuxExecEnviron(buf: []u8, ptrs: [*:null]?[*:0]u8, ptr_cap: usize) bool {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .linux) return false;

    const file = openFileAbsolute("/proc/self/environ", .{}) catch return false;
    defer closeFile(file);
    const len = readFileShort(file, buf) catch return false;

    var count: usize = 0;
    var i: usize = 0;
    while (i < len) {
        if (count + 1 >= ptr_cap) return false;
        const begin = i;
        while (i < len and buf[i] != 0) : (i += 1) {}
        if (i == len) {
            if (len == buf.len) return false;
            buf[i] = 0;
        }
        ptrs[count] = @as([*:0]u8, @ptrCast(buf.ptr + begin));
        count += 1;
        i += 1;
    }
    ptrs[count] = null;
    return true;
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(io(), &mutex.inner);
    }

    pub fn timedWait(self: *Condition, mutex: *Mutex, ns: u64) error{Timeout}!void {
        _ = self;
        mutex.unlock();
        defer mutex.lock();
        sleepNs(ns);
        return error.Timeout;
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};
