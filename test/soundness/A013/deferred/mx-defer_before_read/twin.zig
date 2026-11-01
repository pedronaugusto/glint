// matrix: a defer checks, by aegis's invariant, a local the body writes input into
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader) !u8 {
    var kind: u8 = 0;
    defer aegis.assert.invariant(kind < 4, "a kind is below four");
    kind = try r.takeByte();
    return kind;
}
