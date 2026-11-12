// P007: std.posix.system is std.c or std.os.linux by target: a raw binding either way (review 8, M3).
const std = @import("std");
pub fn f(fd: std.posix.fd_t, b: []u8) isize {
    return std.posix.system.read(fd, b.ptr, b.len);
}
