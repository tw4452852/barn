const c = @import("main.zig").c;
const std = @import("std");

pub const ReqHeader = packed struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
};

pub const ResHeader = packed struct {
    len: u32,
    err: i32,
    unique: u64,
};

pub const bufsize = 0x200000;

var stderr_mutex = std.debug.getStderrMutex();
pub fn fuse_log(_: c_uint, fmt: [*c]const u8, ap: [*c]c.__va_list_tag) callconv(.C) void {
    stderr_mutex.lock();
    defer stderr_mutex.unlock();
    _ = c.vfprintf(c.stderr, fmt, ap);
}
