// matrix: an if expression chooses input on one side, the choice checked by aegis's invariant
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader, wide: bool) !u8 {
    const kind: u8 = if (wide) try r.takeByte() else 3;
    aegis.assert.invariant(kind < 4, "a kind is below four");
    return kind;
}
