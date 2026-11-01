// matrix: a while's payload, each byte a peer sends, refused by an error
const std = @import("std");
fn next(r: *std.Io.Reader) !?u8 {
    const b = try r.takeByte();
    return if (b == 0) null else b;
}
pub fn f(r: *std.Io.Reader) !usize {
    var n: usize = 0;
    while (try next(r)) |b| {
        if (b >= 128) return error.NotAscii;
        n += 1;
    }
    return n;
}
