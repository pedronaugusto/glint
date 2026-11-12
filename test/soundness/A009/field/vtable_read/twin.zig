// A009: the same, in the seam the case declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, file: std.Io.File, data: []const []u8) !usize {
    return io.vtable.fileReadPositional(io.userdata, file, data, 0);
}
