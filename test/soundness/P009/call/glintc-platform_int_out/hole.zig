// P009: the address of a local of a type the system chooses (posix.pid_t), written by a system
// call, given to a part of the struct returned.
const std = @import("std");
const posix = std.posix;
const Held = struct { group: *const posix.pid_t };
pub fn f(fd: posix.fd_t) Held {
    var group: posix.pid_t = 0;
    _ = posix.system.ioctl(fd, 0x40047477, @intFromPtr(&group));
    var out: Held = undefined;
    out.group = &group;
    return out;
}
