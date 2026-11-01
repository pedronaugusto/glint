// matrix: a callee writes input through the pointer it is given, the local then checked by aegis's invariant
const std = @import("std");
const aegis = @import("aegis");
fn fill(out: *u8, r: *std.Io.Reader) !void {
    out.* = try r.takeByte();
}
pub fn f(r: *std.Io.Reader) !u8 {
    var kind: u8 = 0;
    try fill(&kind, r);
    aegis.assert.invariant(kind < 4, "a kind is below four");
    return kind;
}
