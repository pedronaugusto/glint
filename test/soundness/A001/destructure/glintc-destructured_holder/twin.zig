// A001: a holder a destructure names, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(s: *const S) u32 {
    const held, _ = .{ s, @as(u32, 0) };
    return held.expose().*;
}
