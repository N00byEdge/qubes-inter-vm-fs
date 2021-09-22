const std = @import("std");

const server = @import("server.zig");
const comms = @import("comms.zig");

const service_name = "n00byedge.qubes-inter-vm-fs";
const config_dir_path = "/rw/config/inter-vm-fs/";

const fuse = @cImport({
    @cDefine("FUSE_USE_VERSION", "39");
    @cInclude("fuse3/fuse.h");
    @cInclude("fuse3/fuse_common.h");
});

const fuse_ops = fuse.struct_fuse_operations;

var client: Client = undefined;

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
    var result = std.mem.zeroes(fuse.struct_stat);
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
                comms.send(client.writer, comms.Command.stat) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");
                const result = comms.recv(client.reader, i32) catch @panic("");
                if (result == 0) {
                    const st = comms.recv(client.reader, std.os.Stat) catch @panic("");
                    stbuf[0] = to_fuse_stat(st);
                }
                return result;
            }
        }.f,

        .readlink = null,
        .mknod = null,

        .mkdir = struct {
            fn f(path: [*c]const u8, mode: fuse.mode_t) callconv(.C) c_int {
                std.log.info("Client: mkdir '{s}'", .{path});

                comms.send(client.writer, comms.Command.mkdir) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");
                comms.send(client.writer, @intCast(std.os.mode_t, mode)) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .unlink = struct {
            fn f(path: [*c]const u8) callconv(.C) c_int {
                std.log.info("Client: unlink '{s}'", .{path});

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                comms.send(client.writer, comms.Command.unlink) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .rmdir = struct {
            fn f(path: [*c]const u8) callconv(.C) c_int {
                std.log.info("Client: rmdir '{s}'", .{path});

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                comms.send(client.writer, comms.Command.rmdir) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .symlink = null,

        .rename = struct {
            fn f(p1: [*c]const u8, p2: [*c]const u8, flags: c_uint) callconv(.C) c_int {
                _ = flags;
                std.log.info("Client: rename '{s}' -> '{s}'", .{ p1, p2 });

                comms.send(client.writer, comms.Command.rename) catch @panic("");
                comms.sendpath(client.writer, p1) catch @panic("");
                comms.sendpath(client.writer, p2) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
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

                comms.send(client.writer, comms.Command.truncate) catch @panic("");
                comms.send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                comms.send(client.writer, new_size) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .open = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: open '{s}'", .{path});

                comms.send(client.writer, comms.Command.open) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");

                const result = comms.recv(client.reader, i32) catch @panic("");
                std.log.info("Client: open returned {d}", .{result});
                if (result > 0) {
                    do_fi(fi).fh = @intCast(u32, result);
                    return 0;
                }
                return result;
            }
        }.f,

        .read = struct {
            fn f(path: [*c]const u8, bytes: [*c]u8, bytes_len: usize, foff_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: read '{s}' {d} {d}", .{ path, do_fi(fi).fh, bytes_len });

                var foff = @intCast(usize, foff_c);
                const end = bytes_len + foff;

                while (foff < end) {
                    comms.send(client.writer, comms.Command.read) catch @panic("");
                    comms.send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                    comms.send(client.writer, @intCast(u32, end - foff)) catch @panic("");
                    comms.send(client.writer, foff) catch @panic("");

                    const result = comms.recv(client.reader, i32) catch @panic("");

                    std.log.info("Client: going to read {d} bytes, out of {d} remaining", .{ result, end - foff });

                    if (result > 0) {
                        comms.recvinto(client.reader, (bytes + foff - @intCast(usize, foff_c))[0..@intCast(usize, result)]) catch @panic("");
                        foff += @intCast(usize, result);
                    } else if (result < 0) {
                        return result;
                    } else { // result == 0
                        break;
                    }
                }

                return @intCast(c_int, foff - @intCast(usize, foff_c));
            }
        }.f,

        .write = struct {
            fn f(path: [*c]const u8, bytes: [*c]const u8, bytes_len_c: usize, foff_c: fuse.off_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                var foff = @intCast(usize, foff_c);
                const end = bytes_len_c + foff;

                std.log.info("Client: write '{s}' {d}", .{ path, do_fi(fi).fh });

                while (foff < end) {
                    var bytes_len = end - foff;

                    if (bytes_len > comms.max_write_bytes)
                        bytes_len = comms.max_write_bytes;

                    comms.send(client.writer, comms.Command.write) catch @panic("");
                    comms.send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");
                    comms.send(client.writer, @intCast(@TypeOf(comms.max_write_bytes), bytes_len)) catch @panic("");
                    comms.send(client.writer, foff) catch @panic("");

                    comms.sendfrom(client.writer, (bytes + foff - @intCast(usize, foff_c))[0..bytes_len]) catch @panic("");

                    const result = comms.recv(client.reader, i32) catch @panic("");

                    std.log.info("Client: write returned {d}", .{result});

                    if (result > 0) {
                        foff += @intCast(usize, result);
                    } else if (result < 0) {
                        return result;
                    } else { // result == 0
                        break;
                    }
                }

                return @intCast(c_int, foff - @intCast(usize, foff_c));
            }
        }.f,

        .statfs = struct {
            fn f(path: [*c]const u8, stat_buf: [*c]fuse.struct_statvfs) callconv(.C) c_int {
                _ = path;
                stat_buf.*.f_bsize = 512;
                stat_buf.*.f_frsize = 512;

                stat_buf.*.f_blocks = 0x84848484;
                stat_buf.*.f_bfree = 0x42424242;
                stat_buf.*.f_bavail = 0x42424242;

                stat_buf.*.f_files = 696969 * 2;
                stat_buf.*.f_ffree = 696969;
                stat_buf.*.f_favail = 696969;

                return 0;
            }
        }.f,

        .flush = null,

        .release = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: release '{s}' {d}", .{ path, do_fi(fi).fh });

                if (!client.show_as_writeable)
                    return -std.os.EPERM;

                comms.send(client.writer, comms.Command.close) catch @panic("");
                comms.send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");

                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .fsync = null,
        .setxattr = null,
        .getxattr = null,
        .listxattr = null,
        .removexattr = null,

        .opendir = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: opendir '{s}'", .{path});
                comms.send(client.writer, comms.Command.opendir) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");

                const result = comms.recv(client.reader, i32) catch @panic("");
                if (result > 0) {
                    do_fi(fi).fh = @intCast(u32, result);
                    return 0;
                }
                return result;
            }
        }.f,

        .readdir = struct {
            fn f(path: [*c]const u8, bytes: ?*c_void, fill: fuse.fuse_fill_dir_t, _: fuse.off_t, fi: ?*fuse.fuse_file_info, flags: fuse.fuse_readdir_flags) callconv(.C) c_int {
                _ = flags;
                std.log.info("Client: readdir '{s}' {d}", .{ path, do_fi(fi).fh });
                comms.send(client.writer, comms.Command.readdir) catch @panic("");
                comms.send(client.writer, @intCast(i32, do_fi(fi).fh)) catch @panic("");

                while (comms.recv(client.reader, u8) catch @panic("") != 0) {
                    const st = comms.recv(client.reader, std.os.Stat) catch @panic("");
                    const f_path = comms.recvpath(client.reader) catch @panic("");

                    const fuse_st = to_fuse_stat(st);

                    std.log.info("Client: readdir: got dent '{s}'", .{f_path.ptr()});

                    if (fill.?(
                        bytes,
                        f_path.ptr(),
                        &fuse_st,
                        0,
                        std.mem.zeroes(fuse.fuse_fill_dir_flags),
                    ) != 0) {
                        std.log.info("Client: readdir: buffer full, not inserting last dent.", .{});
                        comms.send(client.writer, @as(u8, 0)) catch @panic("");
                        break;
                    }

                    comms.send(client.writer, @as(u8, 1)) catch @panic("");
                }

                return 0;
            }
        }.f,

        .releasedir = struct {
            fn f(path: [*c]const u8, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: releasedir {d} ('{s}')", .{ do_fi(fi).fh, path });
                comms.send(client.writer, comms.Command.releasedir) catch @panic("");
                comms.send(client.writer, @intCast(u32, do_fi(fi).fh)) catch @panic("");
                return comms.recv(client.reader, i32) catch @panic("");
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
                comms.send(client.writer, comms.Command.access) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");
                comms.send(client.writer, flags) catch @panic("");
                return comms.recv(client.reader, i32) catch @panic("");
            }
        }.f,

        .create = struct {
            fn f(path: [*c]const u8, mode: fuse.mode_t, fi: ?*fuse.fuse_file_info) callconv(.C) c_int {
                std.log.info("Client: create '{s}'", .{path});

                comms.send(client.writer, comms.Command.create) catch @panic("");
                comms.sendpath(client.writer, path) catch @panic("");
                comms.send(client.writer, @intCast(std.os.mode_t, mode)) catch @panic("");

                const result = comms.recv(client.reader, i32) catch @panic("");
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

            // stdin/stdout is already connected to the remote, nothing to do
            try server.run(std.io.getStdIn().reader(), std.io.getStdOut().writer(), enable_writing);
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
