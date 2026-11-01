// review 4: rt/a_branch.zig
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader, buf: []u8, c: bool) !u8 {
    const at: usize = try r.takeInt(u32, .little);
    if (c) aegis.assert.invariant(at < buf.len, "at < len");
    return buf[at];
}
