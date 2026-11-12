// A009: a file mapped into memory outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, file: std.Io.File) !std.Io.File.MemoryMap {
    return std.Io.File.MemoryMap.create(io, file, .{ .len = 4096 });
}
