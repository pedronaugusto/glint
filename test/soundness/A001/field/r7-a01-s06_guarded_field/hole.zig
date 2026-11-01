// review 7 pre: a01/s06_guarded_field.zig
const aegis = @import("aegis");
// A guarded value read through @field, past the guard.
pub fn f(g: *aegis.Guarded(u32)) u32 {
    return @field(g, "data");
}
