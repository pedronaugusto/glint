// A009: the read a file reader runs, asked of the Io directly outside a declared input seam (review 8, M4).
const aegis = @import("aegis");
const std = @import("std");
pub fn f(io: std.Io, file: std.Io.File, data: []const []u8) !usize {
    return (try io.operate(.{ .file_read_streaming = .{ .file = file, .data = data } })).file_read_streaming;
}
