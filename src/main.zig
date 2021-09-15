const std = @import("std");

const service_name = "n00byedge.qubes-inter-vm-fs";
const config_dir_path = "/rw/config/inter-vm-fs/";

const fuse = @cImport({
    @cInclude("fuse.h");
});

const client_ops: fuse.fuse_operations = .{
    .getattr = null,
    .readlink = null,
    .getdir = null,
    .mknod = null,
    .mkdir = null,
    .unlink = null,
    .rmdir = null,
    .symlink = null,
    .rename = null,
    .link = null,
    .chmod = null,
    .chown = null,
    .truncate = null,
    .utime = null,
    .open = null,
    .read = null,
    .write = null,
    .statfs = null,
    .flush = null,
    .release = null,
    .fsync = null,
    .setxattr = null,
    .getxattr = null,
    .listxattr = null,
    .removexattr = null,
};

// stdin/stdout is already connected to the remote, nothing to do
pub fn run_server(share_dir: *const std.fs.Dir, enable_writing: bool) !void {
    _ = share_dir;
    _ = enable_writing;
}

pub fn run_client(remote_name: []const u8, share_name: []const u8, mount_dir: []const u8) !void {
    // Spawn the RPC child process
    const service_name_with_arg = service_name ++ "+osdev";

    const rpc = std.ChildProcess.init(&[_][]const u8{
        "qrexec-client-vm", remote_name, service_name_with_arg,
    }, std.heap.page_allocator) catch {
        std.log.err("Could not start RPC process", .{});
        std.os.exit(1);
    };
    defer rpc.deinit();

    try rpc.spawn();
    defer _ = rpc.kill() catch unreachable;

    _ = rpc;

    _ = remote_name;
    _ = share_name;
    _ = mount_dir;
}

pub fn main() !void {
    var arg_it = std.process.args().inner;
    _ = arg_it.skip();

    if(arg_it.next()) |arg| {
        if(std.mem.eql(u8, arg, "client")) {
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
            std.os.exit(0);
        }
        if(std.mem.eql(u8, arg, "server")) {
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
                std.log.err("Could not open share config file", .{});
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
            if(std.mem.indexOfScalar(u8, buffer[0..read_len], '\n')) |nl_pos|
                read_len = nl_pos;

            const path = buffer[0..last_space_pos];
            var flags = buffer[last_space_pos + 1..read_len];

            // Determine the flags
            const enable_writing = std.mem.eql(u8, flags, "rw");

            // Open the directory
            const share_dir = std.fs.openDirAbsolute(path, .{
                .access_sub_paths = true,
                .iterate = true,
                .no_follow = false,
            }) catch {
                std.log.err("Could not open share directory", .{});
                std.os.exit(1);
            };

            std.log.info("Server: Sharing directory '{s}' with writing = {b} (share named {s})", .{
                path, enable_writing, share_name
            });

            try run_server(&share_dir, enable_writing);
            std.os.exit(0);
        }
        std.log.err("Invalid argument: {s} is not a valid mode", .{arg});
        std.os.exit(1);
    }
    else {
        std.log.err("Missing argument: mode", .{});
        std.os.exit(1);
    }
}
