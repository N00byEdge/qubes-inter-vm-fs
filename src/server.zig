const comms = @import("comms.zig");
const std = @import("std");

fn valid_client_fd(fd: i32) bool {
    // 0, 1, 2 are standard
    // 3 -> config dir
    // 4 -> config file
    return fd > 4;
}

pub fn run(reader: std.fs.File.Reader, writer: std.fs.File.Writer, enable_writing: bool) !void {
    try comms.send(writer, @as(u8, @boolToInt(enable_writing)));

    var data_buffer: [comms.max_write_bytes]u8 = undefined;

    while (true) {
        switch (try comms.recv(reader, comms.Command)) {
            .stat => {
                const path = try comms.recvpath(reader);
                var stat_buf = std.mem.zeroes(std.os.Stat);
                const result = @bitCast(i32, @truncate(u32, std.os.linux.stat(path.ptr(), &stat_buf)));
                try comms.send(writer, result);
                if (result == 0)
                    try comms.send(writer, stat_buf);
            },

            .opendir => {
                const path = try comms.recvpath(reader);
                const open_result = @bitCast(i32, @truncate(u32, std.os.linux.open(
                    path.ptr(),
                    std.os.O_RDONLY | std.os.O_CLOEXEC | std.os.O_DIRECTORY | std.os.O_NOCTTY | std.os.O_NONBLOCK,
                    0,
                )));
                try comms.send(writer, open_result);
            },

            .releasedir => {
                const fd = try comms.recv(reader, i32);
                if (!valid_client_fd(fd)) {
                    try comms.send(writer, @as(i32, -std.os.EBADF));
                } else {
                    try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.close(fd))));
                }
            },

            .readdir => {
                const read_fd = try comms.recv(reader, i32);
                if (!valid_client_fd(read_fd)) {
                    try comms.send(writer, @as(u8, 0));
                } else {
                    var dir_to_read = std.fs.Dir{ .fd = read_fd };
                    var it = dir_to_read.iterate();
                    while (true) {
                        if (try it.next()) |dent| {
                            // We got one!
                            try comms.send(writer, @as(u8, 1));

                            // First send the stat
                            var st = std.mem.zeroes(std.os.Stat);
                            st.mode = @intCast(u32, @enumToInt(dent.kind)) << 12;
                            try comms.send(writer, st);

                            // Now send the name
                            try comms.sendpath(writer, @ptrCast([*:0]const u8, dent.name.ptr));

                            // Do you want another one?
                            if (0 == try comms.recv(reader, u8))
                                break;
                        } else {
                            try comms.send(writer, @as(u8, 0));
                            break;
                        }
                    }
                }
            },

            .access => {
                const path = try comms.recvpath(reader);
                const flags = try comms.recv(reader, u32);

                if (flags & std.os.W_OK != 0 and !enable_writing) {
                    try comms.send(writer, @as(i32, -1));
                } else {
                    try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.access(path.ptr(), flags))));
                }
            },

            .open => {
                const path = try comms.recvpath(reader);
                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.open(path.ptr(), if (enable_writing) std.os.O_RDWR else std.os.O_RDONLY, 0))));
            },

            .create => {
                const path = try comms.recvpath(reader);
                const mode = @intCast(usize, try comms.recv(reader, std.os.mode_t));

                if (!enable_writing) {
                    std.log.info("Server: create: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.open(path.ptr(), std.os.O_RDWR | std.os.O_CREAT, mode))));
            },

            .read => {
                const fd = try comms.recv(reader, i32);
                const len = try comms.recv(reader, u32);
                const foff = try comms.recv(reader, std.os.off_t);

                if (!valid_client_fd(fd)) {
                    try comms.send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                var buf = std.mem.span(&data_buffer);

                if (buf.len > len)
                    buf.len = len;

                const result = @bitCast(i64, std.os.linux.pread(fd, buf.ptr, buf.len, foff));
                try comms.send(writer, @intCast(i32, result));
                if (result > 0) {
                    try comms.sendfrom(writer, buf[0..@intCast(usize, result)]);
                }
            },

            .write => {
                const fd = try comms.recv(reader, i32);
                const len = try comms.recv(reader, @TypeOf(comms.max_write_bytes));
                const foff = try comms.recv(reader, std.os.off_t);

                if (!valid_client_fd(fd)) {
                    std.log.info("Server: write: fd misuse", .{});
                    try comms.send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                if (len > comms.max_write_bytes) {
                    @panic("Writing too many bytes!");
                }

                if (!enable_writing) {
                    std.log.info("Server: write: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                var buf = std.mem.span(&data_buffer)[0..len];
                try comms.recvinto(reader, buf);

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.pwrite(fd, buf.ptr, buf.len, foff))));
            },

            .unlink => {
                const path = try comms.recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: unlink: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.unlink(path.ptr()))));
            },

            .truncate => {
                const fd = try comms.recv(reader, i32);
                const new_size = try comms.recv(reader, c_long);

                if (!valid_client_fd(fd)) {
                    std.log.info("Server: write: fd misuse", .{});
                    try comms.send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                if (!enable_writing) {
                    std.log.info("Server: truncate: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.ftruncate(fd, new_size))));
            },

            .mkdir => {
                const path = try comms.recvpath(reader);
                const mode = @intCast(u32, try comms.recv(reader, std.os.mode_t));

                if (!enable_writing) {
                    std.log.info("Server: mkdir: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.mkdir(path.ptr(), mode))));
            },

            .rename => {
                const p1 = try comms.recvpath(reader);
                const p2 = try comms.recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: rename: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.rename(p1.ptr(), p2.ptr()))));
            },

            .rmdir => {
                const path = try comms.recvpath(reader);

                if (!enable_writing) {
                    std.log.info("Server: unlink: writing with writing disabled!", .{});
                    try comms.send(writer, @as(i32, -std.os.EPERM));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.rmdir(path.ptr()))));
            },

            .close => {
                const fd = try comms.recv(reader, i32);

                if (!valid_client_fd(fd)) {
                    std.log.info("Server: write: fd misuse", .{});
                    try comms.send(writer, @as(i32, -std.os.EBADF));
                    continue;
                }

                try comms.send(writer, @bitCast(i32, @truncate(u32, std.os.linux.close(fd))));
            },

            // Anything else is illegal
            _ => std.os.exit(1),
        }
    }
}
