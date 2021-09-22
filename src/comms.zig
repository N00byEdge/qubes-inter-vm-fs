const std = @import("std");

pub const max_write_bytes: u16 = 1024 * 16;

const CommandIntType = u8;

pub const Command = enum(CommandIntType) {
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

pub fn send(writer: std.fs.File.Writer, value: anytype) !void {
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

pub fn sendfrom(writer: std.fs.File.Writer, buf: []const u8) !void {
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

pub fn recv(reader: std.fs.File.Reader, comptime T: type) !T {
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

pub fn recvinto(reader: std.fs.File.Reader, buf: []u8) !void {
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

pub const MAX_PATH_BYTES = std.fs.MAX_PATH_BYTES;

pub const ReadPath = struct {
    buffer: [MAX_PATH_BYTES]u8 = undefined,
    len: usize = 0,

    pub fn ptr(self: *const @This()) [*:0]const u8 {
        return @ptrCast([*:0]const u8, &self.buffer[0]);
    }

    pub fn slice(self: *@This()) []u8 {
        return self.buffer[0..self.len];
    }
};

pub fn recvpath(reader: std.fs.File.Reader) callconv(.Inline) !ReadPath {
    var result: ReadPath = .{};

    result.len = try recv(reader, u16);
    if (result.len > MAX_PATH_BYTES) {
        return error.PathTooLong;
    }

    try recvinto(reader, result.slice());
    return result;
}

pub fn sendpath(writer: std.fs.File.Writer, path: [*:0]const u8) !void {
    const span = std.mem.span(path);

    if (span.len > MAX_PATH_BYTES) {
        return error.PathTooLong;
    }

    try send(writer, @intCast(u16, span.len));
    try sendfrom(writer, span);
}
