// review 4: rt/k_const.zig
const std = @import("std");
const S = struct { buf: []u8 };
pub fn f(r: *std.Io.Reader, a: *S, b: *S) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    if (i >= a.buf.len) return error.Bad;
    const e = i + 1;
    b.buf = b.buf[0..1];
    return a.buf[0..e][0];
}
