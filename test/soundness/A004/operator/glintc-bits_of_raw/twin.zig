// A004: bits, shifts and wrapping arithmetic on a bare value: Zig checks none of them, so no
// check is lost, and the type has no such operation of its own (reactor's parity counter and
// timer wheel, review b9).
const aegis = @import("aegis");
pub fn parity(c: aegis.int.Checked(u32)) bool {
    return c.raw() & 1 == 1;
}
pub fn next(c: aegis.int.Checked(u32)) u32 {
    return c.raw() +% 1;
}
pub fn slot(c: aegis.int.Checked(u64), bits: u6, mask: u64) u64 {
    return (c.raw() >> bits) & mask | (c.raw() ^ mask);
}
