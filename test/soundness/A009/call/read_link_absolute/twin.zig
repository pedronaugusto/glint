// A009: the same, in the seam the case declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, path: []const u8, buffer: []u8) !usize {
    return std.Io.Dir.readLinkAbsolute(io, path, buffer);
}
