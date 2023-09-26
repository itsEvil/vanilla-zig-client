const std = @import("std");

pub fn getpid() std.os.pid_t {
    return std.os.linux.getpid();
}

pub const Stream = std.net.Stream;

pub fn peek(stream: Stream) !bool {
    var bytes_available: i32 = undefined;
    const ret: std.os.linux.E = @enumFromInt(std.c.ioctl(stream.handle, std.os.linux.T.FIONREAD, &bytes_available));
    switch (ret) {
        .BADF => return error.BadFileDescriptor,
        .FAULT => unreachable,
        .INVAL => return error.InvalidRequest,
        .NOTTY => unreachable,
        .SUCCESS => {},
        else => unreachable,
    }
    return bytes_available != 0;
}