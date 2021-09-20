const std = @import("std");

const service_name = "n00byedge.qubes-inter-vm-fs";
const config_dir_path = "/rw/config/inter-vm-fs/";

const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "39");
    @cInclude("fuse3/fuse.h");
    @cInclude("fuse3/fuse_common.h");
});

const fuse_ops = fuse.struct_fuse_operations;

var client: Client = undefined;

const off_t = fuse.off_t;
const mode_t = fuse.mode_t;

const FuseFileInfo = extern struct {
    flags: u32,
    bitfields: [3]u32,
    fh: u64,
    lock_owner: u64,
    poll_events: u32,
};

fn do_fi(fi: ?*fuse.fuse_file_info) *FuseFileInfo {
    return @ptrCast(*FuseFileInfo, @alignCast(@alignOf(FuseFileInfo), fi.?));
}

fn to_fuse_stat(st: std.os.Stat) fuse.struct_stat {
    var result: fuse.struct_stat = undefined;
    result.st_dev = 0;
    result.st_ino = 0;
    result.st_nlink = st.nlink;
    result.st_uid = 0;
    result.st_gid = 0;
    result.st_rdev = 0;
    result.st_mode = st.mode;
    result.st_size = st.size;
    result.st_blocks = st.blocks;
    result.st_blksize = st.blksize;
    result.st_atim.tv_sec = st.atim.tv_sec;
    result.st_atim.tv_nsec = st.atim.tv_nsec;
    result.st_mtim.tv_sec = st.mtim.tv_sec;
    result.st_mtim.tv_nsec = st.mtim.tv_nsec;
    result.st_ctim.tv_sec = st.ctim.tv_sec;
    result.st_ctim.tv_nsec = st.ctim.tv_nsec;
    return result;
}

const Client = struct {
    reader: std.fs.File.Reader,
    writer: std.fs.File.Writer,

    // This just decides if we show everything as readable. It doesn't matter
    // since the remote won't accept writing if we're not allowed to, this is
    // just asking it ahead of time it will allow us or not.
    show_as_writeable: bool,

    fuse_ops: fuse_ops = .{
        .getattr = struct {
            fn f(path: [*c]const u8, stbuf: [*c]fuse.struct_stat, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                if (fi != null) {
                    std.log.info("Client: stat '{s}' {d}", .{ path, do_fi(fi).fh });
                } else {
                    std.log.info("Client: stat '{s}'", .{path});
                }
                send(client.writer, Command.stat) catch @panic("");
                sendpath(client.writer, path) catch @panic("");
                const result = recv(client.reader, i32) catch @panic("");
                if (result == 0) {
                    const st = recv(client.reader, std.os.Stat) catch @panic("");
                    stbuf[0] = to_fuse_stat(st);
                }
                return result;
            }
        }.f,

        .readlink = null,
        .mknod = null,

        .mkdir = struct {
            fn f(path: [*c]const u8, mode: mode_t) callconv(.C) c_int {
                std.log.info("Client: mkdir '{s}'", .{path});

                send(client.writer, Command.mkdir) catch @panic("");
                sendpath(client.writer, path) catch @panic("");
                send(client.writer, mode) catch @panic("");

                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .unlink = struct {
            fn f(path: [*c]const u8) callconv(.C) c_int {
                std.log.info("Client: unlink '{s}'", .{path});

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                send(client.writer, Command.unlink) catch @panic("");
                sendpath(client.writer, path) catch @panic("");

                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .rmdir = struct {
            fn f(path: [*c]const u8) callconv(.C) c_int {
                std.log.info("Client: rmdir '{s}'", .{path});

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                send(client.writer, Command.rmdir) catch @panic("");
                sendpath(client.writer, path) catch @panic("");

                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .symlink = null,

        .rename = struct {
            fn f(p1: [*c]const u8, p2: [*c]const u8, flags: c_uint) callconv(.C) c_int {
                std.log.info("Client: rename '{s}' -> '{s}'", .{ p1, p2 });

                send(client.writer, Command.rename) catch @panic("");
                sendpath(client.writer, p1) catch @panic("");
                sendpath(client.writer, p2) catch @panic("");

                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .link = null,
        .chmod = null,
        .chown = null,

        .truncate = struct {
            fn f(path: [*c]const u8, new_size: c_long, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: truncate '{s}' {d}", .{ path, new_size });

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                send(client.writer, Command.truncate) catch @panic("");
                send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                send(client.writer, new_size) catch @panic("");

                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .open = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: open '{s}'", .{path});

                send(client.writer, Command.open) catch @panic("");
                sendpath(client.writer, path) catch @panic("");

                const result = recv(client.reader, i32) catch @panic("");
                std.log.info("Client: open returned {d}", .{result});
                if (result > 0) {
                    do_fi(fi).fh = @intCast(u32, result);
                    return 0;
                }
                return result;
            }
        }.f,

        .read = struct {
            fn f(path: [*c]const u8, bytes: [*c]u8, bytes_len: usize, foff: off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: read '{s}' {d}", .{ path, do_fi(fi).fh });

                send(client.writer, Command.read) catch @panic("");
                send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                send(client.writer, @intCast(u32, bytes_len)) catch @panic("");
                send(client.writer, foff) catch @panic("");

                const result = recv(client.reader, i32) catch @panic("");

                std.log.info("Client: read returned {d}", .{result});

                if (result > 0) {
                    recvinto(client.reader, bytes[0..@intCast(usize, result)]) catch @panic("");
                }
                return @intCast(c_int, result);
            }
        }.f,

        .write = struct {
            fn f(path: [*c]const u8, bytes: [*c]const u8, bytes_len_c: usize, foff: off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                var bytes_len = bytes_len_c;

                if (bytes_len > max_write_bytes)
                    bytes_len = max_write_bytes;

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                std.log.info("Client: write '{s}' {d}", .{ path, do_fi(fi).fh });

                send(client.writer, Command.write) catch @panic("");
                send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                send(client.writer, @intCast(@TypeOf(max_write_bytes), bytes_len)) catch @panic("");
                send(client.writer, foff) catch @panic("");

                sendfrom(client.writer, bytes[0..bytes_len]) catch @panic("");

                const result = recv(client.reader, i32) catch @panic("");

                std.log.info("Client: write returned {d}", .{result});
                return @intCast(c_int, result);
            }
        }.f,

        .statfs = null,
        .flush = null,
        .release = null,
        .fsync = null,
        .setxattr = null,
        .getxattr = null,
        .listxattr = null,
        .removexattr = null,

        .opendir = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: opendir '{s}'", .{path});
                send(client.writer, Command.opendir) catch @panic("");
                sendpath(client.writer, path) catch @panic("");

                const result = recv(client.reader, i32) catch @panic("");
                if (result > 0) {
                    do_fi(fi).fh = @intCast(u32, result);
                    return 0;
                }
                return result;
            }
        }.f,

        .readdir = struct {
            fn f(path: [*c]const u8, bytes: ?*c_void, fill: fuse.fuse_fill_dir_t, _: off_t, fi: ?*fuse.fuse_file_info, flags: fuse.fuse_readdir_flags) callconv(.C) c_int {
                _ = flags;
                std.log.info("Client: readdir '{s}' {d}", .{ path, do_fi(fi).fh });
                send(client.writer, Command.readdir) catch @panic("");
                send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");

                while (recv(client.reader, u8) catch @panic("") != 0) {
                    const st = recv(client.reader, std.os.Stat) catch @panic("");
                    const f_path = recvpath(client.reader) catch @panic("");

                    const fuse_st = to_fuse_stat(st);

                    std.log.info("Client: readdir: got dent '{s}'", .{f_path.ptr()});

                    if (fill.?(
                        bytes,
                        f_path.ptr(),
                        &fuse_st,
                        0,
                        @intToEnum(fuse.fuse_fill_dir_flags, 0),
                    ) != 0) {
                        std.log.info("Client: readdir: buffer full, not inserting last dent.", .{});
                        send(client.writer, @as(u8, 0)) catch @panic("");
                        break;
                    }

                    send(client.writer, @as(u8, 1)) catch @panic("");
                }

                return 0;
            }
        }.f,

        .releasedir = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: releasedir {d} ('{s}')", .{ do_fi(fi).fh, path });
                send(client.writer, Command.releasedir) catch @panic("");
                send(client.writer, @intCast(u32, do_fi(fi).fh)) catch @panic("");
                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .fsyncdir = null,

        .init = struct {
            fn f(conn: [*c]fuse.struct_fuse_conn_info, cfg: [*c]fuse.struct_fuse_config) callconv(.C) ?*c_void {
                _ = conn;

                cfg[0].use_ino = 0;

                //cfg[0].entry_timeout = 0;
                //cfg[0].attr_timeout = 0;
                //cfg[0].negative_timeout = 0;

                if (!client.show_as_writeable) {
                    // Disable all writing ops
                    client.fuse_ops.mkdir = null;
                    client.fuse_ops.unlink = null;
                    client.fuse_ops.rmdir = null;
                    client.fuse_ops.rename = null;
                    client.fuse_ops.truncate = null;
                    client.fuse_ops.write = null;
                    client.fuse_ops.create = null;
                }

                return fuse.NULL;
            }
        }.f,

        .destroy = null,

        .access = struct {
            fn f(path: [*c]const u8, flags: c_int) callconv(.C) c_int {
                std.log.info("Client: access 0x{X} '{s}'", .{ flags, path });
                send(client.writer, Command.access) catch @panic("");
                sendpath(client.writer, path) catch @panic("");
                send(client.writer, flags) catch @panic("");
                return recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .create = struct {
            fn f(path: [*c]const u8, mode: mode_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: create '{s}'", .{path});

                send(client.writer, Command.create) catch @panic("");
                sendpath(client.writer, path) catch @panic("");
                send(client.writer, mode) catch @panic("");

                const result = recv(client.reader, i32) catch @panic("");
                std.log.info("Client: create returned {d}", .{result});
                if (result > 0) {
                    do_fi(fi).fh = @intCast(u32, result);
                    return 0;
                }
                return result;
            }
        }.f,

        .lock = null,
        .utimens = null,
        .bmap = null,
        .ioctl = null,
        .poll = null,
        .write_buf = null,
        .read_buf = null,
        .flock = null,
        .fallocate = null,
        .copy_file_range = null,
        .lseek = null,
    },
};

const CommandIntType = u8;

const Command = enum(CommandIntType) {
    stat = 0,
    opendir,
    releasedir,
    readdir,
    access,
    open,
    close,
    read,
    write,
    create,
    unlink,
    truncate,
    mkdir,
    rmdir,
    rename,

    _,
};

fn send(writer: std.fs.File.Writer, value: anytype) !void {
    var offset: usize = 0;
    const size = @sizeOf(@TypeOf(value));

    while (offset < size) {
        const val = @bitCast(i64, std.os.linux.write(writer.context.handle, @ptrCast([*]const u8, &value) + offset, size - offset));
        if (val <= 0) {
            std.log.err("Write fail on fd {d}: {d}", .{ writer.context.handle, -val });
            return error.WriteFail;
        }
        offset += @intCast(usize, val);
    }
}

fn sendfrom(writer: std.fs.File.Writer, buf: []const u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const val = @bitCast(i64, std.os.linux.write(writer.context.handle, buf.ptr + offset, buf.len - offset));
        if (val <= 0) {
            std.log.err("Write fail on fd {d}: {d}", .{ writer.context.handle, -val });
            return error.WriteFail;
        }
        offset += @intCast(usize, val);
    }
}

fn recv(reader: std.fs.File.Reader, comptime T: type) !T {
    var value: T = undefined;

    //TODO: Figure out why this doesn't work??
    //try recvinto(reader, std.mem.toBytes(&value)[0..@sizeOf(T)]);

    // We'll just use this for now...
    var offset: usize = 0;
    const size = @sizeOf(T);

    while (offset < size) {
        const val = @bitCast(i64, std.os.linux.read(reader.context.handle, @ptrCast([*]u8, &value) + offset, size - offset));
        if (val <= 0) {
            std.log.err("Read fail on fd {d}: {d}", .{ reader.context.handle, -val });
            return error.ReadFail;
        }
        offset += @intCast(usize, val);
    }

    return value;
}

fn recvinto(reader: std.fs.File.Reader, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const val = @bitCast(i64, std.os.linux.read(reader.context.handle, buf.ptr + offset, buf.len - offset));
        if (val <= 0) {
            std.log.err("Read fail on fd {d}: {d}", .{ reader.context.handle, -val });
            return error.ReadFail;
        }
        offset += @intCast(usize, val);
    }
}

const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;

const ReadPath = struct {
    buffer: [MAX_PATH_BYTES]u8 = undefined,
    len: usize = 0,
    status: c_int = 0,

    fn ptr(self: *const @This()) [*:0]const u8 {
        return @ptrCast([*:0]const u8, &self.buffer[0]);
    }

    fn slice(self: *const @This()) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn recvpath(reader: std.fs.File.Reader) callconv(.Inline) !ReadPath {
    var result: ReadPath = .{};

    while (true) {
        const byte = try recv(reader, u8);
        result.buffer[result.len] = byte;

        result.len += 1;

        if (byte == 0)
            break;

        if (result.len == MAX_PATH_BYTES) {
            return error.PathTooLong;
        }
    }

    return result;
}

fn sendpath(writer: std.fs.File.Writer, path: [*c]const u8) !void {
    var sent: usize = 0;
    while (true) {
        const byte = path[sent];
        try send(writer, byte);
        sent += 1;

        if (byte == 0)
            break;

        if (sent == MAX_PATH_BYTES) // UH OH!!
            return error.PathTooLong;
    }
}

fn valid_client_fd(fd: i32) bool {
    // 0, 1, 2 are standard
    // 3 -> config dir
    // 4 -> config file
    return fd > 4;
}

const max_write_bytes: u16 = 1024 * 16;

// stdin/stdout is already connected to the remote, nothing to do
pub fn run_server(enable_writing: bool) !void {
    const reader = std.io.getStdIn().reader();
    const writer = std.io.getStdOut().writer();

    try send(writer, @as(u8, @boolToInt(enable_writing)));

    var data_buffer: [max_write_bytes]u8 = undefined;

    while (true) {
        switch (try recv(reader, Command)) {
            .stat => {
                const path = try recvpath(reader);
                var stat_buf = std.mem.zeroes(std.os.Stat);
                const result = @bitCast(i32, @truncate(u32, std.os.linux.stat(path.ptr(), &stat_buf)));
                try send(writer, result);
                if (result == 0)
                    try send(writer, stat_buf);
            },

            .opendir => {
                const path = try recvpath(reader);
                const open_result = @bitCast(i32, @truncate(u32, std.os.linux.open(
                    path.ptr(),
                    std.os.O_RDONLY | std.os.O_CLOEXEC | std.os.O_DIRECTORY | std.os.O_NOCTTY | std.os.O_NONBLOCK,
                    0,
                )));
                try send(writer, open_result);
            },

            .releasedir => {
                const fd = try recv(reader, i32);
                if (!valid_client_fd(fd)) {
                    try send(writer, @as(i32, -std.os.EBADF));
                } else {
                    try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.close(fd))));
                }
            },

            .readdir => {
                const read_fd = try recv(reader, i32);
                if (!valid_client_fd(read_fd)) {
                    try send(writer, @as(u8, 0));
                } else {
                    var dir_to_read = std.fs.Dir{ .fd = read_fd };
                    var it = dir_to_read.iterate();
                    while (true) {
                        if (try it.next()) |dent| {
                            // We got one!
                            try send(writer, @as(u8, 1));

                            // First send the stat
                            var st = std.mem.zeroes(std.os.Stat);
                            st.mode = @intCast(u32, @enumToInt(dent.kind)) << 12;
                            try send(writer, st);

                            // Now send the name
                            try sendpath(writer, dent.name.ptr);

                            // Do you want another one?
                            if (0 == try recv(reader, u8))
                                break;
                        } else {
                            try send(writer, @as(u8, 0));
                            break;
                        }
                    }
                }
            },

            .access => {
                const path = try recvpath(reader);
                const flags = try recv(reader, u32);

                if (flags & std.os.W_OK != 0 and !enable_writing) {
                    try send(writer, @as(i32, -1));
                } else {
                    try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.access(path.ptr(), flags))));
                }
            },

            .open => {
                const path = try recvpath(reader);
                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.open(path.ptr(), if (enable_writing) std.os.O_RDWR else std.os.O_RDONLY, 0))));
            },

            .create => {
                const path = try recvpath(reader);
                const mode = @intCast(usize, try recv(reader, mode_t));

                if (!enable_writing) {
                    std.log.info("Server: create: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.open(path.ptr(), std.os.O_RDWR | std.os.O_CREAT, mode))));
            },

            .close => {
                @panic("");
            },

            .read => {
                const fd = try recv(reader, i32);
                const len = try recv(reader, u32);
                const foff = try recv(reader, off_t);

                if (!valid_client_fd(fd)) {
                    try send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                var buf = std.mem.span(&data_buffer);

                if (buf.len > len)
                    buf.len = len;

                const result = @bitCast(i64, std.os.linux.pread(fd, buf.ptr, buf.len, foff));
                try send(writer, @intCast(i32, result));
                if (result > 0) {
                    try sendfrom(writer, buf[0..@intCast(usize, result)]);
                }
            },

            .write => {
                const fd = try recv(reader, i32);
                const len = try recv(reader, @TypeOf(max_write_bytes));
                const foff = try recv(reader, off_t);

                if (!valid_client_fd(fd)) {
                    std.log.info("Server: write: fd misuse", .{});
                    try send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                if (len > max_write_bytes) {
                    @panic("Writing too many bytes!");
                }

                if (!enable_writing) {
                    std.log.info("Server: write: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                var buf = std.mem.span(&data_buffer)[0..len];
                try recvinto(reader, buf);

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.pwrite(fd, buf.ptr, buf.len, foff))));
            },

            .unlink => {
                const path = try recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: unlink: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.unlink(path.ptr()))));
            },

            .truncate => {
                const fd = try recv(reader, i32);
                const new_size = try recv(reader, c_long);

                if (!valid_client_fd(fd)) {
                    std.log.info("Server: write: fd misuse", .{});
                    try send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                if (!enable_writing) {
                    std.log.info("Server: truncate: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.ftruncate(fd, new_size))));
            },

            .mkdir => {
                const path = try recvpath(reader);
                const mode = @intCast(u32, try recv(reader, mode_t));

                if (!enable_writing) {
                    std.log.info("Server: mkdir: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.mkdir(path.ptr(), mode))));
            },

            .rename => {
                const p1 = try recvpath(reader);
                const p2 = try recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: rename: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.rename(p1.ptr(), p2.ptr()))));
            },

            .rmdir => {
                const path = try recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: unlink: writing with writing disabled!", .{});
                    try send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try send(writer, @bitCast(i32, @truncate(u32, std.os.linux.rmdir(path.ptr()))));
            },

            // Anything else is illegal
            _ => std.os.exit(1),
        }
    }
}

const fake_remote_connection = false;

pub fn run_client(remote_name: []const u8, share_name: []const u8, mount_dir: [:0]const u8) !void {
    // Spawn the RPC child process
    var service_name_buffer: [service_name.len + 1 + 256]u8 = undefined;
    std.mem.copy(u8, service_name_buffer[0..], service_name);
    service_name_buffer[service_name.len] = '+';
    std.mem.copy(u8, service_name_buffer[service_name.len + 1 ..], share_name);

    const rpc = std.ChildProcess.init(if (fake_remote_connection) &[_][]const u8{
        service_name, "server", share_name,
    } else &[_][]const u8{
        "qrexec-client-vm",
        remote_name,
        service_name_buffer[0 .. service_name.len + 1 + share_name.len],
    }, std.heap.page_allocator) catch {
        std.log.err("Could not start RPC process", .{});
        std.os.exit(1);
    };
    defer rpc.deinit();

    rpc.stdin_behavior = .Pipe;
    rpc.stdout_behavior = .Pipe;

    try rpc.spawn();
    defer _ = rpc.kill() catch unreachable;

    client = .{
        .reader = rpc.stdout.?.reader(),
        .writer = rpc.stdin.?.writer(),

        .show_as_writeable = (rpc.stdout.?.reader().readIntNative(u8) catch {
            std.log.err("Unable to read writability byte", .{});
            std.os.exit(1);
        }) != 0,
    };

    var progname = [_:0]u8{ 'n', 'o' };

    var fuse_args = fuse.fuse_args{
        .allocated = 0,
        .argc = 1,
        .argv = &[_][*c]u8{
            &progname[0],
        },
    };

    const fuse_inst = fuse.fuse_new(
        &fuse_args,
        &client.fuse_ops,
        @sizeOf(@TypeOf(client.fuse_ops)),
        @intToPtr(*c_void, @ptrToInt(&client)),
    );
    defer fuse.fuse_destroy(fuse_inst);

    if (fuse.fuse_mount(fuse_inst, mount_dir) != 0) {
        std.log.err("Fuse mount failed", .{});
        return;
    }
    defer fuse.fuse_unmount(fuse_inst);

    _ = fuse.fuse_loop(fuse_inst);
}

pub fn main() !void {
    var arg_it = std.process.args().inner;
    _ = arg_it.skip();

    if (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "client")) {
            const remote_name = arg_it.next() orelse {
                std.log.err("No remote name provided", .{});
                std.os.exit(1);
            };
            const share_name = arg_it.next() orelse {
                std.log.err("No share name provided", .{});
                std.os.exit(1);
            };
            const mount_dir = arg_it.next() orelse {
                std.log.err("No mount dir provided", .{});
                std.os.exit(1);
            };

            try run_client(remote_name, share_name, mount_dir);
        }
        if (std.mem.eql(u8, arg, "server")) {
            // Qubes does authentication on the argument, we don't need to worry about it
            const share_name = arg_it.next() orelse {
                std.log.err("No share name provided", .{});
                std.os.exit(1);
            };

            var config_dir = std.fs.openDirAbsolute(config_dir_path, .{
                .access_sub_paths = true,
                .iterate = false,
                .no_follow = false,
            }) catch {
                std.log.err("Could not open share config directory ({s})", .{config_dir_path});
                std.os.exit(1);
            };
            defer config_dir.close();

            const share_file_config = config_dir.openFile(share_name, .{
                .read = true,
                .write = false,
            }) catch {
                std.log.err("Could not open share config file (share {s})", .{share_name});
                std.os.exit(1);
            };
            defer share_file_config.close();

            // Now we need to find out what the local path and mode is of this directory
            // example:
            // path/to/share rw
            // another/path/to/share r

            var buffer: [256]u8 = undefined;
            var read_len = try share_file_config.readAll(buffer[0..]);

            // Last space separates the path from the flags
            const last_space_pos = std.mem.lastIndexOfScalar(u8, buffer[0..read_len], ' ') orelse {
                std.log.err("Invalid config for share '{s}'", .{share_name});
                std.os.exit(1);
            };

            // Cut the buffer off at the first newline, if there is one
            if (std.mem.indexOfScalar(u8, buffer[0..read_len], '\n')) |nl_pos|
                read_len = nl_pos;

            const path = buffer[0..last_space_pos];
            var flags = buffer[last_space_pos + 1 .. read_len];

            // Determine the flags
            const enable_writing = std.mem.eql(u8, flags, "rw");

            if (!fake_remote_connection) {
                buffer[path.len] = 0;
                // Make a new filesystem namespace so that we can chroot
                if (std.os.linux.unshare(std.os.CLONE_NEWUSER) != 0) {
                    @panic("unshare");
                }
                if (std.os.linux.chroot(@ptrCast([*:0]u8, &buffer[0])) != 0) {
                    @panic("chroot");
                }
                if (std.os.linux.chdir("/") != 0) {
                    @panic("chdir");
                }
            }

            try run_server(enable_writing);
        } else if (std.mem.eql(u8, arg, "create_share")) {
            //const share_name = arg_it.next();
            //const client = arg_it.next();
            //const client_path = arg_it.next();
            //const server = arg_it.next();
            //const server_path = arg_it.next();
            //const flags = arg_it.next();
            //const autostart = arg_it.next();

            // dom0: echo 'client server allow' >> /etc/qubes-rpc/policy/{service_name}+{share_name}
            // server: echo '{server_path} {flags}' >> /rw/config/{service_name}/{share_name}
            // If autostart:
            // client: mkdir -p {client_path}
            // client: echo '/usr/bin/{service_name} client {server} {share_name} {client_path}' >> /rw/config/rc.local
            std.log.err("TODO: Implement share creation", .{});
            std.os.exit(1);
        } else if (std.mem.eql(u8, arg, "install_template")) {
            //const template_name = arg_it.next();

            // Set up client and servers in the template
            // template: cp {self} /usr/bin/{service_name}
            // template: echo 'exec /usr/bin/{service_name} server $QREXEC_SERVICE_ARGUMENT'> /etc/qubes-rpc/{service_name}'
            std.log.err("TODO: Implement installation into template", .{});
            std.os.exit(1);
        } else {
            std.log.err("Invalid argument: {s} is not a valid mode", .{arg});
            std.os.exit(1);
        }
    } else {
        std.log.err("Missing argument: mode", .{});
        std.os.exit(1);
    }
}
