// A001: the value's address through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const p = s.expose();
    return p.*;
}
