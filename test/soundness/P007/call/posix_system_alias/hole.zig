// P007: an alias of std.posix.system, used (review 8, M3).
const std = @import("std");
const sys = std.posix.system;
pub fn f(fd: std.posix.fd_t, b: []u8) isize {
    return sys.read(fd, b.ptr, b.len);
}
