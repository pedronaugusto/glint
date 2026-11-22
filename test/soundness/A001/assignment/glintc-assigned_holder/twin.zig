// A001: a holder a var is given, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    var t: *const S = undefined;
    t = s;
    return t.expose().*;
}
