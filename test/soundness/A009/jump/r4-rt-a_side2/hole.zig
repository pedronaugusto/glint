// review 4: rt/a_side2.zig
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader, buf: []u8) !u8 {
    var at: usize = try r.takeInt(u32, .little);
    aegis.assert.invariant(at < buf.len, "at < len");
    aegis.assert.invariant(blk: {
        at += 1;
        break :blk true;
    }, "bumped");
    return buf[at];
}
