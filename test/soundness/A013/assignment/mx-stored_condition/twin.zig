// matrix: a condition on input stored into a variable, then checked by aegis's invariant in every build
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    var ok = false;
    ok = b < 4;
    aegis.assert.invariant(ok, "a kind is below four");
    return b;
}
