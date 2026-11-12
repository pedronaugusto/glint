// A001: the same value read through Secret's own API is no finding.
const aegis = @import("aegis");
pub fn f(s: *const aegis.Secret(u32)) u32 {
    return s.expose().*;
}
