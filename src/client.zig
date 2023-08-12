const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const linux = os.linux;
const os = std.os;
const fs = std.fs;
const c = @import("main.zig").c;
const log = @import("main.zig").lg;
const fuse = @import("fuse.zig");

const Opts = struct {
    port: u16 = 0,
    help: c_int = 0,
    address: [*c]const u8 = null,
    root: [*c]const u8 = null,
    debug: c_int = 0,
};
const opts_spec = [_]c.fuse_opt{
    .{
        .templ = "--port=%u",
        .offset = @offsetOf(Opts, "port"),
        .value = 1,
    },
    .{
        .templ = "-h",
        .offset = @offsetOf(Opts, "help"),
        .value = 1,
    },
    .{
        .templ = "--remote=%s",
        .offset = @offsetOf(Opts, "address"),
        .value = 1,
    },
    .{
        .templ = "--root=%s",
        .offset = @offsetOf(Opts, "root"),
        .value = 1,
    },
    .{
        .templ = "--debug",
        .offset = @offsetOf(Opts, "debug"),
        .value = 1,
    },

    .{
        .templ = null,
        .offset = 0,
        .value = 0,
    },
};

fn usage(args: *c.fuse_args) void {
    std.debug.print(
        \\client [options]
        \\  -h: show this help message
        \\  --debug: show debug log
        \\  --port=[port]: specify the remote port to connect
        \\  --remote=[ip|hostname]: specify the remote host to connect
        \\  --root=[path]: root directory to offer
        \\
        \\Options for fuse:
        \\
    , .{});
    c.fuse_lib_help(args);
}

pub fn main(argv: [][*:0]u8) !void {
    defer log(.info, "client exit\n", .{});
    const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

    c.fuse_set_log_func(fuse.fuse_log);

    var args: c.fuse_args = .{
        .argc = @as(c_int, @intCast(argv.len)),
        .argv = @as([*c][*c]u8, @ptrCast(argv)),
        .allocated = 0,
    };

    var opts: Opts = .{};
    if (c.fuse_opt_parse(&args, &opts, &opts_spec, null) == -1 or opts.help == 1) {
        usage(&args);
        return;
    }
    if (opts.debug == 1) @import("main.zig").effective_log_level = .debug;

    log(.debug, "argv: {s}, opts: {}\n", .{ argv, opts });

    if (opts.port == 0) {
        log(.err, "you must specify the port to connect\n", .{});
        usage(&args);
        return;
    }
    const socket = blk: {
        const remote = if (opts.address) |s| std.mem.sliceTo(s, 0) else "127.0.0.1";
        if (net.Address.parseIp(remote, opts.port)) |address| {
            break :blk try net.tcpConnectToAddress(address);
        } else |_| {
            break :blk try net.tcpConnectToHost(allocator, remote, opts.port);
        }
    };
    defer socket.close();

    const pass_ops = std.mem.zeroInit(c.fuse_operations, .{
        .init = pass_init,
        .getattr = pass_getattr,
        .access = pass_access,
        .open = pass_open,
        .release = pass_release,
        .readdir = pass_readdir,
        .read = pass_read,
        .write = pass_write,
        .create = pass_create,
        .mkdir = pass_mkdir,
        .rmdir = pass_rmdir,
        .unlink = pass_unlink,
        .lseek = pass_lseek,
        .readlink = pass_readlink,
        .flush = pass_flush,
        .truncate = pass_truncate,
    });

    var ctx: Ctx = .{
        .root = if (opts.root != null) std.mem.sliceTo(opts.root, 0) else "/",
        .allocator = allocator,
    };
    log(.debug, "{}\n", .{ctx});
    const s = c.fuse_new(&args, &pass_ops, @sizeOf(c.fuse_operations), &ctx) orelse unreachable;
    defer c.fuse_destroy(s);

    var buf = try allocator.alloc(u8, fuse.bufsize);
    defer allocator.free(buf);
    const str = try std.fmt.bufPrintZ(buf, "/dev/fd/{}", .{try os.dup(socket.handle)});
    var ret = c.fuse_mount(s, @as([*c]const u8, @ptrCast(str)));
    if (ret != 0) {
        log(.err, "client mount failed: {}\n", .{ret});
        return;
    }
    defer c.fuse_unmount(s);

    var se = c.fuse_get_session(s);

    ret = c.fuse_set_signal_handlers(se);
    if (ret != 0) {
        log(.err, "set signal handlers failed: {}\n", .{ret});
        return;
    }
    defer c.fuse_remove_signal_handlers(se);

    defer c.fuse_session_reset(se);

    var fbuf = std.mem.zeroes(c.fuse_buf);
    var left_in_buff: usize = 0;
    while (c.fuse_session_exited(se) == 0) {
        const n = linux.read(socket.handle, buf.ptr + left_in_buff, buf.len - left_in_buff);
        const errno = linux.getErrno(n);
        if (errno == .INTR) {
            continue;
        }
        if (errno != .SUCCESS) {
            log(.err, "recv error: {}\n", .{errno});
            return;
        }
        left_in_buff += n;

        var off: usize = 0;
        while (left_in_buff > 0) {
            const header = @as(*fuse.ReqHeader, @ptrCast(@alignCast(buf.ptr + off)));
            if (header.len > left_in_buff) {
                std.mem.copy(u8, buf[0..left_in_buff], buf[off .. off + left_in_buff]);
                break;
            }

            fbuf.mem = buf.ptr + off;
            fbuf.size = header.len;
            c.fuse_session_process_buf(se, &fbuf);

            off += header.len;
            left_in_buff -= header.len;
        }
    }
}

const Ctx = struct {
    root: []const u8,
    allocator: std.mem.Allocator,
};

const FileInfo = extern struct {
    flags: c_int,

    padding1: u32,
    padding2: u32,
    fh: u64,
    lock_owner: u64,
    poll_events: u32,
};

fn pass_init(ci: [*c]c.fuse_conn_info, cfg: [*c]c.fuse_config) callconv(.C) ?*anyopaque {
    cfg.*.kernel_cache = 1;
    ci.*.want &= @bitReverse(c.FUSE_CAP_SPLICE_READ);

    return c.fuse_get_context().*.private_data;
}

fn pass_getattr(path: [*c]const u8, stbuf: [*c]c.struct_stat, _: ?*c.fuse_file_info) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    return @as(c_int, @intCast(@as(isize, @bitCast(linux.lstat(real_path, @as(*os.Stat, @ptrCast(stbuf)))))));
}

fn pass_access(path: [*c]const u8, mask: c_int) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    return @as(c_int, @intCast(@as(isize, @bitCast(linux.access(real_path, @as(c_uint, @intCast(mask)))))));
}

fn pass_readdir(path: [*c]const u8, buffer: ?*anyopaque, filler: ?*const fn (?*anyopaque, [*c]const u8, [*c]const c.struct_stat, c_long, c_uint) callconv(.C) c_int, offset: c_long, fi: ?*c.fuse_file_info, flags: c_uint) callconv(.C) c_int {
    _ = offset;
    _ = fi;
    _ = flags;

    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    const p = c.opendir(@as([*c]const u8, @ptrCast(real_path)));
    if (p) |dp| {
        defer _ = c.closedir(dp);

        while (c.readdir(dp)) |de| {
            const st = std.mem.zeroInit(c.struct_stat, .{
                .st_mode = @as(u32, @intCast(de.*.d_type)) << 12,
            });
            if (filler.?(buffer, &de.*.d_name, &st, 0, 0) != 0) break;
        }
    } else return -1;

    return 0;
}

fn pass_open(path: [*c]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    const ret = linux.open(real_path, @as(u32, @intCast(p.flags)), 0);
    if (linux.getErrno(ret) != .SUCCESS) {
        return @as(c_int, @intCast(@as(isize, @bitCast(ret))));
    }

    p.fh = @as(u64, @intCast(ret));
    return 0;
}

fn pass_read(_: [*c]const u8, buf: [*c]u8, size: usize, offset: c_long, fi: ?*c.fuse_file_info) callconv(.C) c_int {
    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    const fd = @as(os.fd_t, @intCast(p.fh));
    const f: fs.File = .{ .handle = fd };

    const len = f.getEndPos() catch unreachable;
    if (offset >= len) return 0;

    var want_size = size;
    if (@as(usize, @intCast(offset)) + want_size > len) want_size = len - @as(usize, @intCast(offset));

    const read = linux.pread(fd, buf, want_size, offset);

    return @as(c_int, @intCast(@as(isize, @bitCast(read))));
}

fn pass_release(_: [*c]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    os.close(@as(os.fd_t, @intCast(p.fh)));
    return 0;
}

fn pass_create(path: [*c]const u8, mode: c_uint, fi: ?*c.fuse_file_info) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    const ret = linux.open(real_path, @as(u32, @intCast(p.flags)), mode);
    if (linux.getErrno(ret) != .SUCCESS) {
        return @as(c_int, @intCast(@as(isize, @bitCast(ret))));
    }

    p.fh = @as(u64, @intCast(ret));
    return 0;
}

fn pass_write(_: [*c]const u8, buf: [*c]const u8, size: usize, offset: c_long, fi: ?*c.fuse_file_info) callconv(.C) c_int {
    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    const fd = @as(os.fd_t, @intCast(p.fh));

    const read = linux.pwrite(fd, buf, size, offset);

    return @as(c_int, @intCast(@as(isize, @bitCast(read))));
}

fn pass_mkdir(path: [*c]const u8, mode: c_uint) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    return @as(c_int, @intCast(@as(isize, @bitCast(linux.mkdir(real_path, mode)))));
}

fn pass_rmdir(path: [*c]const u8) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    return @as(c_int, @intCast(@as(isize, @bitCast(linux.rmdir(real_path)))));
}

fn pass_unlink(path: [*c]const u8) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    return @as(c_int, @intCast(@as(isize, @bitCast(linux.unlink(real_path)))));
}

fn pass_lseek(_: [*c]const u8, offset: c_long, whence: c_int, fi: ?*c.fuse_file_info) callconv(.C) c_long {
    const p = @as(*align(1) FileInfo, @ptrCast(fi.?));
    const fd = @as(os.fd_t, @intCast(p.fh));

    return @as(c_long, @intCast(@as(isize, @bitCast(linux.lseek(fd, offset, @as(usize, @intCast(whence)))))));
}

fn pass_readlink(path: [*c]const u8, buf: [*c]u8, size: usize) callconv(.C) c_int {
    const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
    const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
    defer ctx.allocator.free(real_path);

    const ret = linux.readlink(real_path, buf, size - 1);
    if (linux.getErrno(ret) != .SUCCESS) {
        return @as(c_int, @intCast(@as(isize, @bitCast(ret))));
    }

    buf[ret] = 0;
    return 0;
}

fn pass_flush(_: [*c]const u8, _: ?*c.fuse_file_info) callconv(.C) c_int {
    return 0;
}

fn pass_truncate(path: [*c]const u8, size: c_long, fip: ?*c.fuse_file_info) callconv(.C) c_int {
    if (fip) |fi| {
        const p = @as(*align(1) FileInfo, @ptrCast(fi));
        const fd = @as(os.fd_t, @intCast(p.fh));

        return @as(c_int, @intCast(@as(isize, @bitCast(linux.ftruncate(fd, size)))));
    } else {
        const ctx = @as(*align(1) Ctx, @ptrCast(c.fuse_get_context().*.private_data));
        const real_path = std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ ctx.root, path }) catch unreachable;
        defer ctx.allocator.free(real_path);

        const f = fs.cwd().openFile(real_path, .{ .mode = .write_only }) catch unreachable;
        defer f.close();
        return @as(c_int, @intCast(@as(isize, @bitCast(linux.ftruncate(f.handle, size)))));
    }
}
