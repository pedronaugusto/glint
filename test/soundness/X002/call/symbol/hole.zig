// replaces .symbol: an extern that binds the link name is the target: declared by its name, or
// bound to it under another name through @extern.
extern "c" fn fsync(fd: c_int) c_int;
const flushToDisk = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "fsync" });

pub fn f(fd: c_int) c_int {
    return fsync(fd) + flushToDisk(fd);
}
