// P007: std.posix's checked read, through an alias of std.posix.
const std = @import("std");
const posix = std.posix;
pub fn f(fd: posix.fd_t, b: []u8) !usize {
    return posix.read(fd, b);
}
