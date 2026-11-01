// review 4: rt/a_side_safe.zig
const std = @import("std");
const aegis = @import("aegis");
const S = struct { buf: []u8, at: usize };
pub fn f(r: *std.Io.Reader, s: *S) !u8 {
    s.at = try r.takeInt(u32, .little);
    aegis.assert.invariant(s.at < s.buf.len, "at < len");
    aegis.assert.invariant(s.at != 7, "not seven");
    return s.buf[s.at];
}
