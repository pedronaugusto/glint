// A004: a widening cast of the bare value loses nothing (review 8, M8).
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) u64 {
    return @intCast(c.raw());
}
