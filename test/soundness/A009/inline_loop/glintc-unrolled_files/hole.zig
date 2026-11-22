// A009: a reader made over a file an unrolled loop captures, outside a declared input seam: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn open(a: std.Io.File, b: std.Io.File, io: std.Io, buffers: [2][]u8, out: *[2]std.Io.File.Reader) void {
    inline for (.{ a, b }, 0..) |file, i| out[i] = file.reader(io, buffers[i]);
}
