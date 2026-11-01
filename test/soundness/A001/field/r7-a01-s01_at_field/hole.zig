// review 7 pre: a01/s01_at_field.zig
const aegis = @import("aegis");
// The secret's backing field read through @field with its literal name.
pub fn f(s: *const aegis.Secret(u64)) u64 {
    return @field(s, "material");
}
