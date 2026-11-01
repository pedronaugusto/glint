// matrix: aegis's invariant reached by @field with a name held in a constant, its condition on input
const std = @import("std");
const aegis = @import("aegis");
const check = "invariant";
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    @field(aegis.assert, check)(b < 4, "a kind is below four");
    return b;
}
