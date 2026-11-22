// A001: an optional holder unwrapped, read through Secret's API: none.
const aegis = @import("aegis");
const S = aegis.Secret(u32);
pub fn f(o: ?*const S) u32 {
    return o.?.expose().*;
}
