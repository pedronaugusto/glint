// review 4: rt/k_alias.zig
const std = @import("std");
const S = struct { buf: []u8 };
pub fn f(r: *std.Io.Reader, a: *S, b: *S) !u8 {
    const i: usize = try r.takeInt(u32, .little);
    if (i >= a.buf.len) return error.Bad;
    b.buf = b.buf[0..1];
    return a.buf[i];
}
