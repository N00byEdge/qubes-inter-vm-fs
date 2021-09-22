const std = @import("std");

const server = @import("server.zig");
const comms = @import("comms.zig");
const fuse_client = @import("fuse_client.zig");

const service_name = "n00byedge.qubes-inter-vm-fs";
const config_dir_path = "/rw/config/inter-vm-fs/";

const fake_remote_connection = false;

fn spawnProc(proc_cmdline: [][]const u8) !*std.ChildProcess {
    const proc = try std.ChildProcess.init(proc_cmdline, std.heap.page_allocator);
    errdefer proc.deinit();

    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;

    try proc.spawn();
    errdefer _ = proc.kill() catch unreachable;

    return proc;
}

pub fn spawnRemote(remote_name: []const u8, share_name: []const u8) !*std.ChildProcess {
    var service_name_buffer: [service_name.len + 1 + 256]u8 = undefined;

    std.mem.copy(u8, service_name_buffer[0..], service_name);
    service_name_buffer[service_name.len] = '+';
    std.mem.copy(u8, service_name_buffer[service_name.len + 1 ..], share_name);

    return spawnProc(&[_][]const u8{
        "qrexec-client-vm",
        remote_name,
        service_name_buffer[0 .. service_name.len + 1 + share_name.len],
    });
}

pub fn spawnLocal(share_name: []const u8) !*std.ChildProcess {
    return spawnProc(&[_][]const u8{
        service_name,
        "server",
        share_name,
    });
}

fn parseArgsSpawnServer(arg_it: anytype) !*std.ChildProcess {
    const share_name = arg_it.next() orelse {
        std.log.err("No share name provided", .{});
        std.os.exit(1);
    };
    const remote_name = arg_it.next() orelse {
        return spawnLocal(share_name);
    };

    return spawnRemote(remote_name, share_name);
}
 
pub fn main() !void {
    var arg_it = std.process.args().inner;
    _ = arg_it.skip();

    if (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "client")) {
            const mount_dir = arg_it.next() orelse {
                std.log.err("No mount dir provided", .{});
                std.os.exit(1);
            };

            const server_proc = try parseArgsSpawnServer(&arg_it);

            defer _ = server_proc.kill() catch @panic("");
            defer server_proc.deinit();

            return fuse_client.mountDirAndRunClient(server_proc.stdout.?.reader(), server_proc.stdin.?.writer(), mount_dir);
        } else if (std.mem.eql(u8, arg, "server")) {
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
            // client: echo '/usr/bin/{service_name} client {client_path} {share_name} {server}' >> /rw/config/rc.local
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
