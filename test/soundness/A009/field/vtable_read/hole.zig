// A009: the Io implementation's read, called through its table outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, file: std.Io.File, data: []const []u8) !usize {
    return io.vtable.fileReadPositional(io.userdata, file, data, 0);
}
