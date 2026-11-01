// review 4: rt/a_side.zig
const std = @import("std");
const aegis = @import("aegis");
const S = struct { buf: []u8, at: usize };
fn bump(s: *S) bool {
    s.at += 1;
    return true;
}
pub fn f(r: *std.Io.Reader, s: *S) !u8 {
    s.at = try r.takeInt(u32, .little);
    aegis.assert.invariant(s.at < s.buf.len, "at < len");
    aegis.assert.invariant(bump(s), "bumped");
    return s.buf[s.at];
}
