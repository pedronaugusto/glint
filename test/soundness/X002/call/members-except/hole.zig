// replaces .members: every function the container declares is the target, a decoding read as
// much as a byte read; the container's own name is not.
const std = @import("std");

pub fn f(r: *std.Io.Reader) !u32 {
    return r.takeInt(u32, .little);
}
