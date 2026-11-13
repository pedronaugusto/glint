// P009: a pair of descriptors the system writes through the array's address, returned whole:
// integers, which hold no address (conduit close_on_exec.zig, reactor Kqueue's wake pipe).
const std = @import("std");
const posix = std.posix;
pub fn f() ![2]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.pipe(&ends)) != .SUCCESS) return error.SystemResources;
    return ends;
}
