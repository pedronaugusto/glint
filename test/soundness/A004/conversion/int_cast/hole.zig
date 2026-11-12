// A004: a checked integer's bare value cast into a narrower type loses its checks.
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) u16 {
    return @intCast(c.raw());
}
