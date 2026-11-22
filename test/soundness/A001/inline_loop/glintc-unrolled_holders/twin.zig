// A001: an inline for over holders, each read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(a: *const S, b: *const S) u32 {
    var total: u32 = 0;
    inline for (.{ a, b }) |each| total +%= each.expose().*;
    return total;
}
