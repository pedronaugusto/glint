// A009: a writer made over a file unwrapped from an optional by .?: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(given: ?std.Io.File, io: std.Io, buffer: []u8) std.Io.File.Writer {
    return given.?.writer(io, buffer);
}
