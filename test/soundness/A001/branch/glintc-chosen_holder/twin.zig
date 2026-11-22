// A001: a holder an if chooses, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(c: bool, a: *const S, b: *const S) u32 {
    const held = if (c) a else b;
    return held.expose().*;
}
