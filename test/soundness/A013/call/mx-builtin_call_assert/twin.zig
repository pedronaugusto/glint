// matrix: aegis's invariant called through @call with a condition on input
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    @call(.auto, aegis.assert.invariant, .{ b < 4, "a kind is below four" });
    return b;
}
