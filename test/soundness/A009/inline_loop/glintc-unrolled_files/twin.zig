// A009: a writer made over a file an unrolled loop captures: output, none.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(a: std.Io.File, b: std.Io.File, io: std.Io, buffers: [2][]u8, out: *[2]std.Io.File.Writer) void {
    inline for (.{ a, b }, 0..) |file, i| out[i] = file.writer(io, buffers[i]);
}
