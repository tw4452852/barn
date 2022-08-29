const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const os = std.os;
const linux = os.linux;
const c = @import("main.zig").c;
const log = @import("main.zig").lg;

const fuse = @import("fuse.zig");

const Opts = struct {
    port: u16 = 0,
    help: c_int = 0,
    root: ?[*c]const u8 = null,
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
        \\server [options]
        \\  -h: show this help message
        \\  --debug: show debug log
        \\  --port=[port]: specify the port to listen on
        \\  --root=[path]: root directory to mount remote fs onto
        \\
        \\Options for fuse:
        \\
    , .{});
    c.fuse_lib_help(args);
}

pub fn main(argv: [][*:0]u8) !void {
    c.fuse_set_log_func(fuse.fuse_log);

    var args: c.fuse_args = .{
        .argc = @intCast(c_int, argv.len),
        .argv = @ptrCast([*c][*c]u8, argv),
        .allocated = 0,
    };
    var opts: Opts = .{};
    if (c.fuse_opt_parse(&args, &opts, &opts_spec, null) == -1 or opts.help == 1) {
        usage(&args);
        return;
    }
    if (opts.debug == 1) @import("main.zig").effective_log_level = .debug;

    log(.debug, "argv: {s}, opts: {}\n", .{ argv, opts });

    const localhost = try net.Address.parseIp("0.0.0.0", opts.port);

    var server = net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(localhost);
    log(.info, "listening on {}\n", .{server.listen_address});

    while (true) {
        const conn = try server.accept();
        const t = try std.Thread.spawn(.{}, serve, .{ &opts, &args, conn });
        if (builtin.is_test) {
            t.join();
            break;
        }
        t.detach();
    }
    log(.info, "server exit\n", .{});
}

fn serve(opts: *const Opts, args: *c.fuse_args, conn: net.StreamServer.Connection) !void {
    defer {
        conn.stream.close();
        log(.info, "serving from {} exit\n", .{conn.address});
    }

    const null_ops = std.mem.zeroes(c.fuse_lowlevel_ops);

    const s = c.fuse_session_new(args, &null_ops, @sizeOf(c.fuse_lowlevel_ops), null) orelse unreachable;
    defer c.fuse_session_destroy(s);

    var buf: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&buf, "/tmp/barn_{}", .{conn.address});
    const root = if (opts.root) |r| std.mem.sliceTo(r, 0) else tmp_path;
    if (std.fs.makeDirAbsolute(root)) {} else |e| {
        if (e != error.PathAlreadyExists) return e;
    }
    log(.info, "serving from {}, the mirror root directory: {s}\n", .{ conn.address, root });
    defer std.fs.deleteTreeAbsolute(root) catch {};
    var ret = c.fuse_session_mount(s, @ptrCast([*c]const u8, root));
    if (ret != 0) {
        log(.err, "mount failed: {}\n", .{ret});
        return;
    }
    defer c.fuse_session_unmount(s);

    const devfd = c.fuse_session_fd(s);

    const r = try std.Thread.spawn(.{}, sendOut, .{ devfd, conn.stream.handle });
    r.detach();

    const w = try std.Thread.spawn(.{}, recvIn, .{ conn.stream.handle, devfd });
    defer w.join();
}

fn createPipe() ![2]os.fd_t {
    const pipe = try os.pipe();

    _ = try os.fcntl(pipe[0], 1031, fuse.bufsize);
    _ = try os.fcntl(pipe[1], 1031, fuse.bufsize);
    return pipe;
}

fn destroyPipe(pipe: [2]os.fd_t) void {
    os.close(pipe[0]);
    if (pipe[0] != pipe[1]) os.close(pipe[1]);
}

const SPLICE_F_MOVE = 1;
const SPLICE_F_NONBLOCK = 2;
const SPLICE_F_MORE = 4;

fn splice(from: os.fd_t, to: os.fd_t, len: usize) !usize {
    const n = os.linux.syscall6(os.linux.SYS.splice, @bitCast(usize, @as(isize, from)), 0, @bitCast(usize, @as(isize, to)), 0, len, SPLICE_F_MOVE);
    const err = linux.getErrno(n);
    if (err != .SUCCESS) {
        if (err == .NOENT) {
            // operation interrupted
            return len;
        }
        log(.err, "splice failed: {}\n", .{err});
        return error.Unexpected;
    }
    if (n == 0) return error.EOF;
    return n;
}

fn spliceAll(from: os.fd_t, to: os.fd_t, len: usize) !void {
    var left = len;
    while (left > 0) {
        const n = try splice(from, to, left);
        left -= n;
    }
}

fn get_header(comptime T: type, from: os.fd_t, header_pipe: [2]os.fd_t) !T {
    const tid = std.Thread.getCurrentId();

    var header: T = undefined;
    const headerSize = @sizeOf(T);
    const iov: os.iovec = .{
        .iov_base = @ptrCast([*]u8, &header),
        .iov_len = headerSize,
    };

    var n = linux.syscall4(linux.SYS.tee, @bitCast(usize, @as(isize, from)), @bitCast(usize, @as(isize, header_pipe[1])), headerSize, 0);
    var err = linux.getErrno(n);
    if (err != .SUCCESS) {
        log(.err, "{} failed to get length, tee: {}\n", .{ tid, err });
        return @intToError(@enumToInt(err));
    }
    if (n < headerSize) return error.TOOSHORT;

    err = linux.getErrno(linux.syscall4(linux.SYS.vmsplice, @bitCast(usize, @as(isize, header_pipe[0])), @ptrToInt(&iov), 1, 0));
    if (err != .SUCCESS) {
        log(.err, "{} failed to get length, vmsplice: {}\n", .{ tid, err });
        return @intToError(@enumToInt(err));
    }

    return header;
}

fn sendOut(from: os.fd_t, to: os.fd_t) void {
    const tid = std.Thread.getCurrentId();
    defer log(.debug, "{} sendOut exit\n", .{tid});

    forward(fuse.ReqHeader, from, to) catch |e| {
        log(.debug, "{}: {}\n", .{ tid, e });
        return;
    };
}

fn recvIn(from: os.fd_t, to: os.fd_t) void {
    const tid = std.Thread.getCurrentId();
    defer log(.debug, "{} recvIn exit\n", .{tid});

    forward(fuse.ResHeader, from, to) catch |e| {
        log(.debug, "{}: {}\n", .{ tid, e });
        return;
    };
}

fn forward(comptime T: type, from: os.fd_t, to: os.fd_t) !void {
    const tid = std.Thread.getCurrentId();

    const pipe = try createPipe();
    defer destroyPipe(pipe);

    const header_pipe = try os.pipe();
    defer destroyPipe(header_pipe);

    var left_in_buf: usize = 0;
    while (true) {
        log(.debug, "{} splice waiting, left {} in buffer ...\n", .{ tid, left_in_buf });

        var buffered = try splice(from, pipe[1], fuse.bufsize);
        left_in_buf += buffered;

        // construct a complete pkt at least
        var header = get_header(T, pipe[0], header_pipe) catch |e| if (e == error.TOOSHORT) {
            continue;
        } else return e;
        const left = header.len -| left_in_buf;
        if (left > 0) {
            try spliceAll(from, pipe[1], left);
            buffered += left;
            left_in_buf += left;
        }
        log(.debug, "{} spliced {} to pipe...\n", .{ tid, buffered });

        // split into pkts if any
        while (left_in_buf > 0) {
            header = get_header(T, pipe[0], header_pipe) catch |e| if (e == error.TOOSHORT) {
                break;
            } else return e;

            if (left_in_buf < header.len) break;
            try spliceAll(pipe[0], to, header.len);
            log(.debug, "{} spliced {} from pipe...\n", .{ tid, header.len });
            left_in_buf -= header.len;
        }
    }
}
