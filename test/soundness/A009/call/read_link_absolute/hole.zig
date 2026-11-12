// A009: a link read by absolute path outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, path: []const u8, buffer: []u8) !usize {
    return std.Io.Dir.readLinkAbsolute(io, path, buffer);
}
