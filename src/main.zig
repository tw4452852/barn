const std = @import("std");
const testing = std.testing;
const os = std.os;
const fs = std.fs;
const print = std.debug.print;
pub const c = @cImport({
    if (@import("builtin").abi == .musl) {
        @cInclude("timespec.h"); // this struct in musl has bitfields, so this hack
    }

    @cDefine("FUSE_USE_VERSION", "35");
    @cInclude("fuse_lowlevel.h");
    @cInclude("fuse.h");

    @cInclude("stdio.h");
    @cInclude("dirent.h");
    @cInclude("signal.h");
    @cInclude("stdarg.h");
});

const server = @import("server.zig");
const client = @import("client.zig");

fn usage() void {
    print("{s} [server|client] [options]\n", .{os.argv[0]});
}

pub var effective_log_level: std.log.Level = .info;
pub fn lg(
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    if (@enumToInt(message_level) <= @enumToInt(effective_log_level)) {
        std.debug.print(format, args);
    }
}

pub fn main() anyerror!void {
    const args = os.argv;

    if (args.len < 2) {
        usage();
        return;
    }

    const cmd = std.mem.sliceTo(args[1], 0);
    const cmdArgs = args[1..];

    if (std.mem.eql(u8, cmd, "server")) {
        return server.main(cmdArgs);
    } else if (std.mem.eql(u8, cmd, "client")) {
        return client.main(cmdArgs);
    } else {
        usage();
    }
}

const clientRoot = "/tmp/client_root";
const serverRoot = "/tmp/server_root";
const port = "12345";
test {
    fs.deleteTreeAbsolute(clientRoot) catch {};
    try fs.makeDirAbsolute(clientRoot);
    defer {
        fs.deleteTreeAbsolute(clientRoot) catch {};
        fs.deleteTreeAbsolute(serverRoot) catch {};
    }

    var clientArgs = [_][*:0]u8{
        try std.testing.allocator.dupeZ(u8, "client"),
        try std.testing.allocator.dupeZ(u8, "--root=" ++ clientRoot),
        try std.testing.allocator.dupeZ(u8, "--port=" ++ port),
        try std.testing.allocator.dupeZ(u8, "--remote=127.0.0.1"),
        try std.testing.allocator.dupeZ(u8, "--debug"),
        try std.testing.allocator.dupeZ(u8, "-d"),
    };
    defer for (clientArgs) |a| std.testing.allocator.free(std.mem.sliceTo(a, 0));
    var serverArgs = [_][*:0]u8{
        try std.testing.allocator.dupeZ(u8, "server"),
        try std.testing.allocator.dupeZ(u8, "--root=" ++ serverRoot),
        try std.testing.allocator.dupeZ(u8, "--port=" ++ port),
        try std.testing.allocator.dupeZ(u8, "-o"),
        try std.testing.allocator.dupeZ(u8, "allow_other"),
        try std.testing.allocator.dupeZ(u8, "--debug"),
        try std.testing.allocator.dupeZ(u8, "-d"),
    };
    defer for (serverArgs) |a| std.testing.allocator.free(std.mem.sliceTo(a, 0));

    const srv = try std.Thread.spawn(.{}, server.main, .{&serverArgs});
    defer srv.join();

    std.time.sleep(1 * std.time.ns_per_s);
    const cli = try std.Thread.spawn(.{}, client.main, .{&clientArgs});
    defer cli.join();

    std.time.sleep(1 * std.time.ns_per_s);
    print("setup done\n", .{});
    defer {
        print("finishing...\n", .{});

        const handle = cli.getHandle();
        _ = c.pthread_kill(if (@import("builtin").abi == .musl) @intToPtr(c.pthread_t, @ptrToInt(handle)) else @ptrToInt(handle), os.SIG.HUP);
    }

    testRead() catch |e| {
        print("testRead failed: {}\n", .{e});
        return e;
    };
    testWrite() catch |e| {
        print("testWrite failed: {}\n", .{e});
        return e;
    };
    testOverwrite() catch |e| {
        print("testOverwrite failed: {}\n", .{e});
        return e;
    };
    testSeek() catch |e| {
        print("testSeek failed: {}\n", .{e});
        return e;
    };
    testMakeDir() catch |e| {
        print("testMakeDir failed: {}\n", .{e});
        return e;
    };
    testReadDir() catch |e| {
        print("testReadDir failed: {}\n", .{e});
        return e;
    };
    testRemoveDir() catch |e| {
        print("testRemoveDir failed: {}\n", .{e});
        return e;
    };
    testRemoveFile() catch |e| {
        print("testRemoveFile failed: {}\n", .{e});
        return e;
    };
    testReadLink() catch |e| {
        print("testReadLink failed: {}\n", .{e});
        return e;
    };
}

fn testRead() !void {
    const expected = "123";
    _ = try fs.cwd().writeFile(clientRoot ++ "/1.txt", expected);

    var buf: [16]u8 = undefined;
    const actual = try fs.cwd().readFile(serverRoot ++ "/1.txt", &buf);

    try testing.expectEqualStrings(actual, expected);
}

fn testWrite() !void {
    const expected = "123";
    _ = try fs.cwd().writeFile(serverRoot ++ "/2.txt", expected);

    var buf: [16]u8 = undefined;
    const actual = try fs.cwd().readFile(clientRoot ++ "/2.txt", &buf);

    try testing.expectEqualStrings(actual, expected);
}

fn testOverwrite() !void {
    const expected = "456";
    _ = try fs.cwd().writeFile(serverRoot ++ "/1.txt", expected);

    var buf: [16]u8 = undefined;
    const actual = try fs.cwd().readFile(clientRoot ++ "/1.txt", &buf);

    try testing.expectEqualStrings(actual, expected);
}

fn testSeek() !void {
    const f = try fs.openFileAbsolute(serverRoot ++ "/2.txt", .{});
    defer f.close();

    const off: u64 = 1;
    try f.seekTo(off);
    try testing.expectEqual(off, try f.getPos());

    var buf: [16]u8 = undefined;
    const n = try f.read(&buf);
    try testing.expectEqualStrings("23", buf[0..n]);

    try testing.expectEqual(try f.getEndPos(), try f.getPos());
}

fn testMakeDir() !void {
    try fs.makeDirAbsolute(serverRoot ++ "/test");
    try fs.accessAbsolute(clientRoot ++ "/test", .{});
}

fn testReadDir() !void {
    const root = try fs.openIterableDirAbsolute(serverRoot, .{});
    const expected = [_]fs.IterableDir.Entry{
        .{ .name = "2.txt", .kind = .File },
        .{ .name = "1.txt", .kind = .File },
        .{ .name = "test", .kind = .Directory },
    };

    var actual = std.ArrayList(fs.IterableDir.Entry).init(testing.allocator);
    defer actual.deinit();
    var iter = root.iterate();
    while (try iter.next()) |entry| {
        try actual.append(entry);
    }

    try testing.expectEqual(expected.len, actual.items.len);
    for (actual.items) |got| {
        try testing.expect(contains(&expected, got));
    }
}

fn contains(set: []const fs.IterableDir.Entry, got: fs.IterableDir.Entry) bool {
    for (set) |ent| {
        if (ent.kind == got.kind and std.mem.eql(u8, ent.name, got.name)) return true;
    }
    return false;
}

fn testRemoveDir() !void {
    try fs.deleteDirAbsolute(serverRoot ++ "/test");
    try testing.expectError(os.AccessError.FileNotFound, fs.accessAbsolute(clientRoot ++ "/test", .{}));
}

fn testRemoveFile() !void {
    try fs.deleteFileAbsolute(serverRoot ++ "/1.txt");
    try testing.expectError(os.AccessError.FileNotFound, fs.accessAbsolute(clientRoot ++ "/1.txt", .{}));
}

fn testReadLink() !void {
    try os.symlink("./test", clientRoot ++ "/test_link");
    var buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    _ = try fs.readLinkAbsolute(serverRoot ++ "/test_link", &buf);
}
