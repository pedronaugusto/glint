// P009: an integer of a type the system chooses (posix.pid_t), written through its address by
// a system call, holds no address to return (conduit tty.zig's foreground group).
const std = @import("std");
const posix = std.posix;
pub fn f(fd: posix.fd_t) posix.pid_t {
    var group: posix.pid_t = 0;
    _ = posix.system.ioctl(fd, 0x40047477, @intFromPtr(&group));
    return group;
}
