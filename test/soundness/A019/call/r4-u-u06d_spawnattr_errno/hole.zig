// review 4: u/u06d_spawnattr_errno.zig
// A019: posix_spawnattr_init also answers the error number itself; errno(rc) shows nothing.
const std = @import("std");
pub fn attr() ?std.c.posix_spawnattr_t {
    var a: std.c.posix_spawnattr_t = undefined;
    if (std.c.errno(std.c.posix_spawnattr_init(&a)) != .SUCCESS) return null;
    return a;
}
