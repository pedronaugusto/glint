// A009: the same, in the seam the case declares.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, file: std.Io.File) !std.Io.File.MemoryMap {
    return std.Io.File.MemoryMap.create(io, file, .{ .len = 4096 });
}
