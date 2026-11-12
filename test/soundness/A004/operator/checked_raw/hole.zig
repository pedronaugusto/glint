// A004: Checked's bare value given straight to a comparison loses its checks.
const aegis = @import("aegis");
pub fn f(c: aegis.int.Checked(u32)) bool {
    return c.raw() > 3;
}
