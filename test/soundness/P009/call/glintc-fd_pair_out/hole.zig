// P009: a slice of the local pair, which the return frees.
const std = @import("std");
const posix = std.posix;
pub fn f() ![]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.pipe(&ends)) != .SUCCESS) return error.SystemResources;
    return ends[0..];
}
